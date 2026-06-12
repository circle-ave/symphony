defmodule SymphonyElixir.ModelRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Codex.ModelRouter
  alias SymphonyElixir.Linear.Issue

  test "disabled model router preserves the configured codex command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex base app-server",
      codex_model_router: %{}
    )

    issue = issue_fixture()

    assert {:ok, route} = ModelRouter.route_for_test(issue, "/tmp/workspace", [])
    assert route.profile == "default"
    assert route.command == "codex base app-server"
    assert route.source == :default
  end

  test "enabled model router selects a configured profile from router JSON" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex base app-server",
      codex_model_router: router_config()
    )

    test_pid = self()

    turn_runner = fn workspace, prompt, issue, opts ->
      send(test_pid, {:router_called, workspace, prompt, issue.identifier, opts})
      {:ok, ~s({"profile":"deep","confidence":0.91,"reason":"retry with migration risk"})}
    end

    issue = issue_fixture(state: "Rework", labels: ["backend", "migration"])

    assert {:ok, route} =
             ModelRouter.route_for_test(issue, "/tmp/router-workspace",
               attempt: 2,
               turn_runner: turn_runner
             )

    assert route.profile == "deep"
    assert route.command == "codex deep app-server"
    assert route.reason == "retry with migration risk"
    assert route.confidence == 0.91
    assert route.source == :router

    assert_receive {:router_called, "/tmp/router-workspace", prompt, "MT-ROUTE", opts}
    assert prompt =~ "You are Symphony's model router"
    assert prompt =~ "Attempt: 2"
    assert prompt =~ "- deep: Architecture, migrations, failed retries, or risky user-facing changes."
    assert opts[:command] == "codex router app-server"
    assert opts[:approval_policy] == "never"
    assert opts[:turn_sandbox_policy] == %{"type" => "readOnly", "networkAccess" => true}
  end

  test "model router falls back to the default profile when output is unusable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex base app-server",
      codex_model_router: router_config()
    )

    turn_runner = fn _workspace, _prompt, _issue, _opts ->
      {:ok, ~s({"profile":"unknown","reason":"bad id"})}
    end

    assert {:ok, route} =
             ModelRouter.route_for_test(issue_fixture(), "/tmp/router-workspace", turn_runner: turn_runner)

    assert route.profile == "standard"
    assert route.command == "codex standard app-server"
    assert route.source == :fallback
    assert route.reason == "model router returned no usable profile"
  end

  test "agent runner launches the selected model profile command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-model-router-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      previous_trace = System.get_env("SYMP_TEST_MODEL_ROUTER_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_MODEL_ROUTER_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_MODEL_ROUTER_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_MODEL_ROUTER_TRACE", trace_file)
      File.mkdir_p!(test_root)

      File.write!(codex_binary, fake_codex_router_script())
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} base",
        codex_model_router: %{
          enabled: true,
          router_command: "#{codex_binary} router",
          default_profile: "standard",
          profiles: %{
            standard: %{command: "#{codex_binary} standard", description: "Normal implementation."},
            deep: %{command: "#{codex_binary} deep", description: "Risky implementation."}
          }
        }
      )

      issue = issue_fixture()
      state_fetcher = fn [issue_id] -> {:ok, [%{issue | id: issue_id, state: "Done"}]} end

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher, max_turns: 1)

      trace = File.read!(trace_file)
      assert trace =~ "MODE:router"
      assert trace =~ "MODE:deep"
      refute trace =~ "MODE:base"
    after
      File.rm_rf(test_root)
    end
  end

  defp router_config do
    %{
      enabled: true,
      router_command: "codex router app-server",
      default_profile: "standard",
      profiles: %{
        fast: %{command: "codex fast app-server", description: "Small docs or mechanical edits."},
        standard: %{command: "codex standard app-server", description: "Normal implementation work."},
        deep: %{
          command: "codex deep app-server",
          description: "Architecture, migrations, failed retries, or risky user-facing changes."
        }
      }
    }
  end

  defp issue_fixture(overrides \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "issue-route",
          identifier: "MT-ROUTE",
          title: "Route model for ticket",
          description: "Pick an appropriate model profile.",
          state: "In Progress",
          labels: ["backend"],
          blocked_by: [],
          priority: 2,
          url: "https://example.org/MT-ROUTE"
        ],
        overrides
      )
    )
  end

  defp fake_codex_router_script do
    """
    #!/bin/sh
    mode="$1"
    trace_file="${SYMP_TEST_MODEL_ROUTER_TRACE:-/tmp/symphony-model-router.trace}"
    printf 'MODE:%s\\n' "$mode" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s:%s\\n' "$mode" "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-router"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-router"}}}'
          if [ "$mode" = "router" ]; then
            printf '%s\\n' '{"method":"item/completed","params":{"msg":{"type":"agent_message","message":"{\\"profile\\":\\"deep\\",\\"confidence\\":0.96,\\"reason\\":\\"needs senior review\\"}"}}}'
          fi
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """
  end
end
