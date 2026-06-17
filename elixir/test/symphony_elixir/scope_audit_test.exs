defmodule SymphonyElixir.ScopeAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ScopeAudit

  test "scope audit decodes a bounded blocked verdict" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-audit-blocked-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-700")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")

      File.mkdir_p!(workspace)
      write_fake_scope_codex!(codex_binary, "blocked", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        scope_audit: %{
          enabled: true,
          command: "#{codex_binary} app-server",
          max_tokens: 40_000,
          timeout_ms: 5_000
        }
      )

      issue = %Issue{
        id: "issue-scope-blocked",
        identifier: "MT-700",
        title: "Generate assets",
        description: "Generate missing logo and product imagery. https://github.com/example/repo/pull/1",
        state: "In Progress",
        url: "https://example.org/issues/MT-700",
        labels: ["symphony"]
      }

      audit_result = ScopeAudit.run(issue, workspace, self())

      assert match?({:ok, %ScopeAudit.Result{}}, audit_result),
             "audit result: #{inspect(audit_result)}\ntrace:\n#{File.read!(trace_file)}"

      {:ok, %ScopeAudit.Result{} = result} = audit_result
      assert result.verdict == :blocked
      assert result.summary == "Ambiguous asset workflow"
      assert result.intended_workflow == "Tenant asks an agent to replace assets."
      assert result.target_surfaces == "blocked"
      assert result.acceptance_source == "ticket body and linked PR metadata"
      assert result.evidence == ["No module asset inventory is defined."]
      assert result.confusions == ["Which module asset slots are targetable?"]
      assert File.read!(trace_file) =~ ~s("dynamicTools":[])

      assert_receive {:codex_worker_update, "issue-scope-blocked", %{event: :scope_audit_prepared}}, 500
    after
      File.rm_rf(test_root)
    end
  end

  test "scope audit decodes current app-server agent message events" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-audit-current-events-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-702")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")

      File.mkdir_p!(workspace)
      write_fake_scope_codex!(codex_binary, "current-events", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        scope_audit: %{
          enabled: true,
          command: "#{codex_binary} app-server",
          max_tokens: 40_000,
          timeout_ms: 5_000
        }
      )

      issue = %Issue{
        id: "issue-scope-current-events",
        identifier: "MT-702",
        title: "Generate assets",
        description: "Generate missing logo and product imagery.",
        state: "In Progress",
        url: "https://example.org/issues/MT-702",
        labels: []
      }

      assert {:ok, %ScopeAudit.Result{} = result} = ScopeAudit.run(issue, workspace, self())
      assert result.verdict == :blocked
      assert result.summary == "Current event shape"
      assert result.confusions == ["Which asset slots are targetable?"]
    after
      File.rm_rf(test_root)
    end
  end

  test "scope audit stops when its token budget is exceeded" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-scope-audit-budget-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-701")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "fake-codex.trace")

      File.mkdir_p!(workspace)
      write_fake_scope_codex!(codex_binary, "over-budget", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        scope_audit: %{
          enabled: true,
          command: "#{codex_binary} app-server",
          max_tokens: 50,
          timeout_ms: 5_000
        }
      )

      issue = %Issue{
        id: "issue-scope-budget",
        identifier: "MT-701",
        title: "Generate assets",
        description: "Generate missing logo and product imagery.",
        state: "In Progress",
        url: "https://example.org/issues/MT-701",
        labels: []
      }

      audit_result = ScopeAudit.run(issue, workspace, self())

      assert audit_result == {:error, {:scope_audit_token_budget_exceeded, 125, 50}},
             "audit result: #{inspect(audit_result)}\ntrace:\n#{File.read!(trace_file)}"
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_scope_codex!(path, mode, trace_file) do
    File.write!(path, fake_scope_codex_script(mode, trace_file))
    File.chmod!(path, 0o755)
  end

  defp fake_scope_codex_script(mode, trace_file) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s:%s\\n' "$count" "$line" >> "$trace_file"
      case "$count" in
        1)
          printf 'response:%s\\n' '{"id":1,"result":{}}' >> "$trace_file"
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf 'response:%s\\n' '{"id":2,"result":{"thread":{"id":"thread-scope"}}}' >> "$trace_file"
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-scope"}}}'
          ;;
        4)
          printf 'response:%s\\n' '{"id":3,"result":{"turn":{"id":"turn-scope"}}}' >> "$trace_file"
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-scope"}}}'
          if [ "#{mode}" = "over-budget" ]; then
            printf 'response:%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":125}}}}' >> "$trace_file"
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":125}}}}'
            sleep 10
          else
            printf 'response:%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":12}}}}' >> "$trace_file"
            printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":12}}}}'
            if [ "#{mode}" = "current-events" ]; then
              printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"ignore {\\"verdict\\":\\"clear\\"}"}]}}}'
              printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"{\\"verdict\\":\\"blocked\\","}}'
              printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"delta":"\\"summary\\":\\"Current event shape\\",\\"intended_workflow\\":\\"blocked\\",\\"target_surfaces\\":\\"blocked\\",\\"acceptance_source\\":\\"ticket\\",\\"evidence\\":[\\"Modern app-server events stream deltas.\\"],\\"confusions\\":[\\"Which asset slots are targetable?\\"]}"}}'
              printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"{\\"verdict\\":\\"blocked\\",\\"summary\\":\\"Current event shape\\",\\"intended_workflow\\":\\"blocked\\",\\"target_surfaces\\":\\"blocked\\",\\"acceptance_source\\":\\"ticket\\",\\"evidence\\":[\\"Modern app-server events stream deltas.\\"],\\"confusions\\":[\\"Which asset slots are targetable?\\"]}"}}}'
            else
              printf 'response:%s\\n' '{"method":"item/completed","params":{"msg":{"type":"agent_message","message":"{\\"verdict\\":\\"blocked\\",\\"summary\\":\\"Ambiguous asset workflow\\",\\"intended_workflow\\":\\"Tenant asks an agent to replace assets.\\",\\"target_surfaces\\":\\"blocked\\",\\"acceptance_source\\":\\"ticket body and linked PR metadata\\",\\"evidence\\":[\\"No module asset inventory is defined.\\"],\\"confusions\\":[\\"Which module asset slots are targetable?\\"]}"}}}' >> "$trace_file"
              printf '%s\\n' '{"method":"item/completed","params":{"msg":{"type":"agent_message","message":"{\\"verdict\\":\\"blocked\\",\\"summary\\":\\"Ambiguous asset workflow\\",\\"intended_workflow\\":\\"Tenant asks an agent to replace assets.\\",\\"target_surfaces\\":\\"blocked\\",\\"acceptance_source\\":\\"ticket body and linked PR metadata\\",\\"evidence\\":[\\"No module asset inventory is defined.\\"],\\"confusions\\":[\\"Which module asset slots are targetable?\\"]}"}}}'
            fi
            printf 'response:%s\\n' '{"method":"turn/completed"}' >> "$trace_file"
            printf '%s\\n' '{"method":"turn/completed"}'
          fi
          ;;
      esac
    done
    """
  end
end
