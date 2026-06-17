defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  defmodule RetryLinearClient do
    def fetch_candidate_issues do
      send(self(), :retry_fetch_candidate_issues)
      {:ok, []}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:retry_fetch_issues_by_states, states})
      {:ok, []}
    end

    def fetch_issue_states_by_ids(ids) do
      send(self(), {:retry_fetch_issue_states_by_ids, ids})
      {:ok, Process.get({__MODULE__, :issues}, [])}
    end
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.waiting_state == nil
    assert config.tracker.comment_reply_states == []
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20
    assert config.agent.max_turn_tokens == nil
    assert config.agent.max_run_tokens == nil
    assert config.agent.scope_audit.enabled == false
    assert config.agent.scope_audit.max_tokens == 40_000
    assert config.agent.roles == %{}

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), tracker_comment_reply_states: ["In Review"])
    assert Config.settings!().tracker.comment_reply_states == ["In Review"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_waiting_state: "Waiting")
    assert Config.settings!().tracker.waiting_state == "Waiting"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turn_tokens"

    write_workflow_file!(Workflow.workflow_file_path(), max_run_tokens: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_run_tokens"

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 90_000, max_run_tokens: 180_000)
    assert Config.settings!().agent.max_turn_tokens == 90_000
    assert Config.settings!().agent.max_run_tokens == 180_000

    write_workflow_file!(Workflow.workflow_file_path(),
      scope_audit: %{enabled: true, command: "codex-mini app-server", max_tokens: 20_000, timeout_ms: 120_000}
    )

    assert Config.settings!().agent.scope_audit.enabled == true
    assert Config.settings!().agent.scope_audit.command == "codex-mini app-server"
    assert Config.settings!().agent.scope_audit.max_tokens == 20_000
    assert Config.settings!().agent.scope_audit.timeout_ms == 120_000

    write_workflow_file!(Workflow.workflow_file_path(), scope_audit: %{enabled: true, max_tokens: 0})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.scope_audit.max_tokens"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{
        "waiting_blocker_audit" => %{
          "command" => "echo ok",
          "cwd" => System.tmp_dir!(),
          "interval_ms" => 123,
          "timeout_ms" => 456,
          "run" => "pre_dispatch"
        }
      }
    )

    assert Config.settings!().agent.roles == %{
             "waiting_blocker_audit" => %{
               "command" => "echo ok",
               "cwd" => System.tmp_dir!(),
               "interval_ms" => 123,
               "timeout_ms" => 456,
               "run" => "pre_dispatch"
             }
           }

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{"bad" => %{"command" => "", "interval_ms" => 0}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.roles"

    assert Schema.normalize_agent_roles(nil) == %{}
    assert Schema.normalize_agent_roles(%{"raw" => "echo ok"}) == %{"raw" => "echo ok"}

    write_workflow_file!(Workflow.workflow_file_path(), agent_roles: %{"bad" => "not-a-map"})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "roles must be maps"

    write_workflow_file!(Workflow.workflow_file_path(), agent_roles: %{"bad" => %{}})
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "role command must be a string"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{"bad" => %{"command" => "echo ok", "cwd" => 123}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "role cwd must be a string"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{"bad" => %{"command" => "echo ok", "enabled" => "yes"}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "role enabled must be a boolean"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{"bad" => %{"command" => "echo ok", "run" => "post_dispatch"}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "role run must be pre_dispatch"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{"ok" => %{"command" => "echo ok", "enabled" => true}}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "pre-dispatch agent roles run commands on their interval" do
    role_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-role-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(role_root)
    File.mkdir_p!(role_root)
    on_exit(fn -> File.rm_rf(role_root) end)

    role_log = Path.join(role_root, "role.log")

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_roles: %{
        "waiting_blocker_audit" => %{
          "command" => "printf run >> role.log",
          "cwd" => role_root,
          "interval_ms" => 1_000,
          "timeout_ms" => 5_000
        }
      }
    )

    state = %Orchestrator.State{agent_role_due_at_ms: %{}}
    state = Orchestrator.run_due_agent_roles_for_test(state, :pre_dispatch, 100)

    assert File.read!(role_log) == "run"
    assert state.agent_role_status["waiting_blocker_audit"].status == "ok"
    assert state.agent_role_status["waiting_blocker_audit"].last_exit_status == 0
    assert is_integer(state.agent_role_status["waiting_blocker_audit"].last_duration_ms)

    state = Orchestrator.run_due_agent_roles_for_test(state, :pre_dispatch, 101)
    assert File.read!(role_log) == "run"

    state = %{state | agent_role_due_at_ms: %{"waiting_blocker_audit" => 100}}
    _state = Orchestrator.run_due_agent_roles_for_test(state, :pre_dispatch, 100)

    assert File.read!(role_log) == "runrun"
  end

  test "freeze checkpoints running agents and resume reopens dispatch" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-freeze-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    issue = %Issue{
      id: "issue-freeze",
      identifier: "MT-FREEZE",
      title: "Freeze running agent",
      state: "In Progress",
      url: "https://linear.app/example/issue/MT-FREEZE"
    }

    pid =
      spawn(fn ->
        receive do
          :done -> :ok
        after
          60_000 -> :ok
        end
      end)

    ref = Process.monitor(pid)
    started_at = DateTime.add(DateTime.utc_now(), -10, :second)

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: pid,
          ref: ref,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: workspace,
          session_id: "thread-freeze",
          last_codex_message: "working on restartable state",
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :notification,
          codex_stream_window: [
            %{event: :notification, message: "recent checkpoint evidence", timestamp: DateTime.utc_now()}
          ],
          codex_input_tokens: 10,
          codex_output_tokens: 20,
          codex_total_tokens: 30,
          turn_count: 2,
          retry_attempt: 1,
          started_at: started_at
        }
      },
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {frozen_state, payload} = Orchestrator.freeze_for_test(state, reason: "test freeze")

    Process.sleep(20)
    refute Process.alive?(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert payload.status == "frozen"
    assert payload.stopped_running_count == 1
    assert frozen_state.running == %{}
    assert frozen_state.freeze.active == true

    retry = frozen_state.retry_attempts[issue.id]
    assert retry.delay_type == :frozen_restart
    assert retry.timer_ref == nil
    assert retry.retry_token == nil
    assert retry.resume_checkpoint_path == Path.join(workspace, ".symphony/resume.json")

    checkpoint = retry.resume_checkpoint_path |> File.read!() |> Jason.decode!()
    assert checkpoint["schema"] == "symphony.resume.v1"
    assert checkpoint["issue"]["identifier"] == "MT-FREEZE"
    assert checkpoint["session"]["session_id"] == "thread-freeze"
    assert [%{"message" => "recent checkpoint evidence"}] = checkpoint["codex"]["stream_window"]

    {resumed_state, resume_payload} = Orchestrator.resume_for_test(frozen_state)

    assert resume_payload.status == "resuming"
    assert resumed_state.freeze == nil
    assert resumed_state.retry_attempts == %{}
    refute MapSet.member?(resumed_state.claimed, issue.id)
    assert is_reference(resumed_state.tick_timer_ref)
    Process.cancel_timer(resumed_state.tick_timer_ref)
  end

  test "prompt builder appends resume checkpoint context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Work {{ issue.identifier }}")

    issue = %Issue{id: "issue-resume", identifier: "MT-RESUME", state: "In Progress"}

    prompt =
      PromptBuilder.build_prompt(issue,
        resume_checkpoint: %{
          "path" => "/tmp/workspace/.symphony/resume.json",
          "frozen_at" => "2026-05-29T00:00:00Z",
          "issue" => %{"identifier" => "MT-RESUME", "state" => "In Progress"},
          "session" => %{"session_id" => "thread-resume", "turn_count" => 3},
          "codex" => %{
            "last_message" => "agent was validating",
            "stream_window" => [%{"message" => "last visible status"}]
          }
        }
      )

    assert prompt =~ "Work MT-RESUME"
    assert prompt =~ "Symphony resume checkpoint"
    assert prompt =~ "Resume from the preserved workspace"
    assert prompt =~ "last visible status"
  end

  test "prompt builder ignores invalid resume checkpoints and defaults partial checkpoint fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Work {{ issue.identifier }}")

    issue = %Issue{id: "issue-resume-defaults", identifier: "MT-RESUME-DEFAULTS", state: "In Progress"}

    assert PromptBuilder.build_prompt(issue, resume_checkpoint: :invalid) == "Work MT-RESUME-DEFAULTS"

    prompt =
      PromptBuilder.build_prompt(issue,
        resume_checkpoint: %{
          "issue" => "not-a-map",
          "session" => %{},
          "codex" => %{"stream_window" => []}
        }
      )

    assert prompt =~ "Symphony resume checkpoint"
    assert prompt =~ "operator restart at unknown"
    assert prompt =~ "Checkpoint file: n/a"
    assert prompt =~ "Issue: unknown / unknown"
    assert prompt =~ "Previous session: unknown; turns completed: 0"
    refute prompt =~ "Recent stream before freeze"
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    refute Map.has_key?(tracker, "project_slug")
    assert is_list(Map.get(tracker, "active_states"))
    assert Map.get(tracker, "comment_reply_states") == ["Human Review", "In Review"]
    assert is_list(Map.get(tracker, "terminal_states"))

    repositories = Map.get(config, "repositories", %{})
    assert Map.get(repositories, "selected") == "symphony"

    assert [%{"id" => "symphony", "url" => "https://github.com/openai/symphony", "branch" => "main", "tracker" => repo_tracker}] =
             Map.get(repositories, "allowed")

    assert repo_tracker["project_slug"] == "symphony-0c79b11b75ea"

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    refute Map.has_key?(hooks, "before_remove")

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear oauth token resolves from LINEAR_OAUTH_ACCESS_TOKEN env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_linear_oauth_access_token = System.get_env("LINEAR_OAUTH_ACCESS_TOKEN")
    env_oauth_access_token = "test-linear-oauth-token"

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("LINEAR_OAUTH_ACCESS_TOKEN", previous_linear_oauth_access_token)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.put_env("LINEAR_OAUTH_ACCESS_TOKEN", env_oauth_access_token)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_oauth_access_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == nil
    assert Config.settings!().tracker.oauth_access_token == env_oauth_access_token
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "jira auth resolves from JIRA env vars" do
    previous_jira_site = System.get_env("JIRA_SITE")
    previous_jira_email = System.get_env("JIRA_EMAIL")
    previous_jira_api_token = System.get_env("JIRA_API_TOKEN")

    on_exit(fn ->
      restore_env("JIRA_SITE", previous_jira_site)
      restore_env("JIRA_EMAIL", previous_jira_email)
      restore_env("JIRA_API_TOKEN", previous_jira_api_token)
    end)

    System.put_env("JIRA_SITE", "https://circleavenue.atlassian.net")
    System.put_env("JIRA_EMAIL", "agent@example.com")
    System.put_env("JIRA_API_TOKEN", "jira-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      jira_site: nil,
      jira_email: nil,
      jira_api_token: nil
    )

    assert Config.settings!().jira.site == "https://circleavenue.atlassian.net"
    assert Config.settings!().jira.email == "agent@example.com"
    assert Config.settings!().jira.api_token == "jira-token"
  end

  test "jira auth falls back to workflow-adjacent dotenv values" do
    previous_jira_site = System.get_env("JIRA_SITE")
    previous_jira_site_url = System.get_env("JIRA_SITE_URL")
    previous_jira_email = System.get_env("JIRA_EMAIL")
    previous_jira_api_token = System.get_env("JIRA_API_TOKEN")

    on_exit(fn ->
      restore_env("JIRA_SITE", previous_jira_site)
      restore_env("JIRA_SITE_URL", previous_jira_site_url)
      restore_env("JIRA_EMAIL", previous_jira_email)
      restore_env("JIRA_API_TOKEN", previous_jira_api_token)
    end)

    System.delete_env("JIRA_SITE")
    System.delete_env("JIRA_SITE_URL")
    System.delete_env("JIRA_EMAIL")
    System.delete_env("JIRA_API_TOKEN")

    dotenv_path = Path.join(Path.dirname(Workflow.workflow_file_path()), ".env")

    File.write!(dotenv_path, """
    JIRA_SITE_URL="https://circleave-dotenv.atlassian.net"
    JIRA_EMAIL="dotenv-agent@example.com"
    JIRA_API_TOKEN="dotenv-jira-token"
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      jira_site: nil,
      jira_email: nil,
      jira_api_token: nil
    )

    assert Config.settings!().jira.site == "https://circleave-dotenv.atlassian.net"
    assert Config.settings!().jira.email == "dotenv-agent@example.com"
    assert Config.settings!().jira.api_token == "dotenv-jira-token"
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "waiting issue state lets running agent finish final writes" do
    issue_id = "issue-waiting"
    issue_identifier = "MT-557"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "In Review"],
      tracker_waiting_state: "Waiting",
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
    )

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "Waiting",
      title: "Parked",
      description: "Agent parked issue after scope gate",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert %{^issue_id => running_entry} = updated_state.running
    assert running_entry.issue.state == "Waiting"
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert Process.alive?(agent_pid)

    send(agent_pid, :stop)
  end

  test "turn token budget stops and blocks running agent without retry" do
    issue_id = "issue-token-turn"
    issue_identifier = "MT-558"

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 1_000, max_run_tokens: 2_000)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    ref = Process.monitor(agent_pid)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: ref,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          session_id: "thread-turn-1",
          started_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_stream_window: [],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_turn_base_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    {:noreply, updated_state} =
      Orchestrator.handle_info(
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "codex/event/token_count",
             "params" => %{
               "msg" => %{
                 "type" => "token_count",
                 "info" => %{
                   "total_token_usage" => %{
                     "input_tokens" => 1_000,
                     "output_tokens" => 25,
                     "total_tokens" => 1_025
                   }
                 }
               }
             }
           },
           timestamp: DateTime.utc_now()
         }},
        state
      )

    refute Map.has_key?(updated_state.running, issue_id)
    assert updated_state.retry_attempts == %{}
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert %{^issue_id => blocked_entry} = updated_state.blocked
    assert blocked_entry.error == "turn token budget exceeded: total_tokens=1025 limit=1000"
    assert blocked_entry.tokens.total_tokens == 1_025
    assert blocked_entry.tokens.current_turn_tokens == 1_025
    assert updated_state.codex_totals.total_tokens == 1_025

    Process.sleep(20)
    refute Process.alive?(agent_pid)
  end

  test "turn token budget uses last token usage instead of cumulative session total" do
    issue_id = "issue-token-turn-last-usage"
    issue_identifier = "MT-570"

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 1_000, max_run_tokens: 5_000)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    ref = Process.monitor(agent_pid)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: ref,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          session_id: "thread-turn-1",
          started_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_stream_window: [],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_turn_base_total_tokens: 0,
          codex_last_delta_total_tokens: 0,
          codex_last_usage_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    {:noreply, updated_state} =
      Orchestrator.handle_info(
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "type" => "token_count",
             "info" => %{
               "total_token_usage" => %{
                 "input_tokens" => 1_500,
                 "output_tokens" => 101,
                 "total_tokens" => 1_601
               },
               "last_token_usage" => %{
                 "input_tokens" => 650,
                 "output_tokens" => 51,
                 "total_tokens" => 701
               }
             }
           },
           timestamp: DateTime.utc_now()
         }},
        state
      )

    assert %{^issue_id => running_entry} = updated_state.running
    assert running_entry.codex_total_tokens == 1_601
    assert running_entry.codex_last_delta_total_tokens == 1_601
    assert running_entry.codex_last_usage_total_tokens == 701
    assert updated_state.blocked == %{}
    assert updated_state.codex_totals.total_tokens == 1_601

    send(agent_pid, :stop)
  end

  test "comment reply turn token budget is capped below normal turn budget" do
    issue_id = "issue-comment-token-cap"
    issue_identifier = "MT-569"

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 90_000)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    ref = Process.monitor(agent_pid)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: ref,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Review", identifier: issue_identifier},
          comment_reply: true,
          session_id: "thread-comment-reply",
          started_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_stream_window: [],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_turn_base_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    {:noreply, updated_state} =
      Orchestrator.handle_info(
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "codex/event/token_count",
             "params" => %{
               "msg" => %{
                 "type" => "token_count",
                 "info" => %{
                   "total_token_usage" => %{
                     "input_tokens" => 60_000,
                     "output_tokens" => 1,
                     "total_tokens" => 60_001
                   }
                 }
               }
             }
           },
           timestamp: DateTime.utc_now()
         }},
        state
      )

    refute Map.has_key?(updated_state.running, issue_id)
    assert %{^issue_id => blocked_entry} = updated_state.blocked
    assert blocked_entry.error == "turn token budget exceeded: total_tokens=60001 limit=60000"
    assert updated_state.retry_attempts == %{}

    Process.sleep(20)
    refute Process.alive?(agent_pid)
  end

  test "run token budget uses cumulative tokens while turn budget resets per turn" do
    issue_id = "issue-token-run"
    issue_identifier = "MT-559"

    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 1_000, max_run_tokens: 1_500)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          5_000 -> :ok
        end
      end)

    ref = Process.monitor(agent_pid)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: ref,
          identifier: issue_identifier,
          issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
          session_id: "thread-turn-1",
          started_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_stream_window: [],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 900,
          codex_turn_base_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 900,
          turn_count: 1
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    {:noreply, next_turn_state} =
      Orchestrator.handle_info(
        {:codex_worker_update, issue_id,
         %{
           event: :session_started,
           session_id: "thread-turn-2",
           timestamp: DateTime.utc_now()
         }},
        state
      )

    assert get_in(next_turn_state.running, [issue_id, :codex_turn_base_total_tokens]) == 900

    {:noreply, updated_state} =
      Orchestrator.handle_info(
        {:codex_worker_update, issue_id,
         %{
           event: :notification,
           payload: %{
             "method" => "thread/tokenUsage/updated",
             "params" => %{
               "tokenUsage" => %{
                 "total" => %{"inputTokens" => 1_550, "outputTokens" => 51, "totalTokens" => 1_601}
               }
             }
           },
           timestamp: DateTime.utc_now()
         }},
        next_turn_state
      )

    refute Map.has_key?(updated_state.running, issue_id)
    assert updated_state.retry_attempts == %{}
    assert %{^issue_id => blocked_entry} = updated_state.blocked
    assert blocked_entry.error == "run token budget exceeded: total_tokens=1601 limit=1500"
    assert blocked_entry.tokens.total_tokens == 1_601
    assert blocked_entry.tokens.current_turn_tokens == 701

    Process.sleep(20)
    refute Process.alive?(agent_pid)
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "waiting issues without blocker signals recover to Rework with a comment" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-recovery-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-waiting",
      identifier: "MT-701",
      title: "Waiting without blockers",
      state: "Waiting",
      blocked_by: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :WaitingRecoveryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
    end)

    send(pid, :tick)

    assert_receive {:memory_tracker_comment, "issue-waiting", body}, 500
    assert body =~ "Operator auto-recovery"
    assert body =~ "symphony-waiting-auto-recovery"
    assert_receive {:memory_tracker_state_update, "issue-waiting", "Rework"}, 500
  end

  test "waiting blocker monitor dispatches eligible blocker issues" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-blocker-dispatch-#{System.unique_integer([:positive])}"
      )

    waiting_issue = %Issue{
      id: "issue-waiting-blocked",
      identifier: "MT-704",
      title: "Waiting for dependency",
      state: "Waiting",
      blocked_by: [%{id: "issue-blocker", identifier: "MT-705", state: "Todo"}]
    }

    blocker_issue = %Issue{
      id: "issue-blocker",
      identifier: "MT-705",
      title: "Resolve dependency",
      state: "Todo",
      blocked_by: []
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_waiting_state: "Waiting",
      codex_command: "sleep 60",
      codex_read_timeout_ms: 10,
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [waiting_issue, blocker_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    try do
      assert {:ok, state} =
               Orchestrator.run_waiting_blocker_monitor_for_test(%Orchestrator.State{
                 running: %{},
                 claimed: MapSet.new(),
                 blocked: %{},
                 retry_attempts: %{},
                 max_concurrent_agents: 2,
                 poll_interval_ms: 30_000
               })

      assert Map.has_key?(state.running, blocker_issue.id)
      assert MapSet.member?(state.claimed, blocker_issue.id)
      refute MapSet.member?(state.claimed, waiting_issue.id)
      assert state.waiting_blocker_monitor_status.scanned_count == 1
      assert state.waiting_blocker_monitor_status.blocked_waiting_count == 1
      assert state.waiting_blocker_monitor_status.blocker_candidate_count == 1
      assert state.waiting_blocker_monitor_status.dispatched_count == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "waiting issues with live resource gate markers stay in Waiting" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-resource-gate-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-waiting-gated",
      identifier: "MT-702",
      title: "Waiting with gate marker",
      state: "Waiting",
      blocked_by: []
    }

    marker_dir = Path.join([test_root, issue.identifier, ".symphony"])
    File.mkdir_p!(marker_dir)
    File.write!(Path.join(marker_dir, "cloud-gate-blocked"), "Example App Cloud SSH auth unavailable\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :WaitingResourceGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
    end)

    send(pid, :tick)
    refute_receive {:memory_tracker_state_update, "issue-waiting-gated", _state}, 300
    refute_receive {:memory_tracker_comment, "issue-waiting-gated", _body}, 300
  end

  test "waiting issues with human blocker markers stay in Waiting" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-human-blocker-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-waiting-human-blocker",
      identifier: "MT-703",
      title: "Waiting for product input",
      state: "Waiting",
      blocked_by: []
    }

    marker_dir = Path.join([test_root, issue.identifier, ".symphony"])
    File.mkdir_p!(marker_dir)
    File.write!(Path.join(marker_dir, "waiting-blocked"), "missing source screenshots\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :WaitingHumanBlockerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
    end)

    send(pid, :tick)
    refute_receive {:memory_tracker_state_update, "issue-waiting-human-blocker", _state}, 300
    refute_receive {:memory_tracker_comment, "issue-waiting-human-blocker", _body}, 300
  end

  test "waiting issues with product-scope workpad confusions stay in Waiting" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-confusions-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-waiting-confusions",
      identifier: "MT-706",
      title: "Waiting for product scope",
      state: "Waiting",
      blocked_by: [],
      active_workpad_body: """
      ## Codex Workpad

      ### Status
      Waiting for product scope.

      ### Confusions
      - Which modules should this feature cover?
      - What demo behavior should be accepted as complete?

      ### Demo / Review Recipe
      Blocked until product scope is clarified.
      """
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    try do
      assert {:ok, state} =
               Orchestrator.run_waiting_blocker_monitor_for_test(%Orchestrator.State{
                 running: %{},
                 claimed: MapSet.new(),
                 blocked: %{},
                 retry_attempts: %{},
                 max_concurrent_agents: 2,
                 poll_interval_ms: 30_000
               })

      assert state.waiting_blocker_monitor_status.scanned_count == 1
      assert state.waiting_blocker_monitor_status.recovered_count == 0
      refute_receive {:memory_tracker_state_update, "issue-waiting-confusions", _state}, 300
      refute_receive {:memory_tracker_comment, "issue-waiting-confusions", _body}, 300
    after
      File.rm_rf(test_root)
    end
  end

  test "waiting issues with review-demo workpad confusions recover to Rework" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-waiting-demo-rework-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-waiting-demo-rework",
      identifier: "MT-707",
      title: "Waiting for review details",
      state: "Waiting",
      blocked_by: [],
      active_workpad_body: """
      ## Codex Workpad

      ### Status
      Waiting for reviewer-accessible demo details.

      ### Confusions
      - Missing exact no-setup `Open:` URL for the review demo.

      ### Demo / Review Recipe
      No reviewer-accessible demo can be derived yet.
      """
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    try do
      assert {:ok, state} =
               Orchestrator.run_waiting_blocker_monitor_for_test(%Orchestrator.State{
                 running: %{},
                 claimed: MapSet.new(),
                 blocked: %{},
                 retry_attempts: %{},
                 max_concurrent_agents: 2,
                 poll_interval_ms: 30_000
               })

      assert state.waiting_blocker_monitor_status.scanned_count == 1
      assert state.waiting_blocker_monitor_status.recovered_count == 1
      assert_receive {:memory_tracker_state_update, "issue-waiting-demo-rework", "Rework"}, 500
      assert_receive {:memory_tracker_comment, "issue-waiting-demo-rework", body}, 500
      assert body =~ "returning this issue to `Rework`"
    after
      File.rm_rf(test_root)
    end
  end

  test "active issues with live resource gate locks park before dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-active-resource-gate-#{System.unique_integer([:positive])}"
      )

    lock_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-active-resource-lock-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-active-gated",
      identifier: "MT-703",
      title: "Active with gate marker",
      state: "Rework",
      blocked_by: []
    }

    marker_dir = Path.join([test_root, issue.identifier, ".symphony"])
    File.mkdir_p!(marker_dir)
    File.mkdir_p!(lock_dir)
    File.write!(Path.join(marker_dir, "cloud-gate-blocked"), "lock=#{lock_dir}\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      tracker_active_states: ["Rework", "In Progress"],
      tracker_waiting_state: "Waiting",
      cloud_gate_retry_cooldown_ms: 60_000,
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :ActiveResourceGateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
      File.rm_rf(lock_dir)
    end)

    send(pid, :tick)
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert MapSet.member?(state.claimed, issue.id)
    assert %{delay_type: :cloud_gate, workspace_path: workspace_path} = state.retry_attempts[issue.id]
    assert workspace_path == Path.join(test_root, issue.identifier)
  end

  test "active issues with opaque resource markers remain dispatchable" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-cloud-gate-opaque-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Path.join([workspace, ".symphony", "cloud-gate-blocked"]),
      "Example App Cloud deploy-state blocker; no live lock or async job is present\n"
    )

    on_exit(fn -> File.rm_rf(workspace) end)

    refute Orchestrator.resource_gate_retry_still_blocked_for_test?(%{
             delay_type: :cloud_gate,
             workspace_path: workspace
           })
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile keeps running comment reply agent in comment reply state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_comment_reply_states: ["In Review"],
      tracker_terminal_states: ["Done"]
    )

    issue_id = "issue-comment-reconcile"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(agent_pid), do: Process.exit(agent_pid, :shutdown)
    end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-565",
          comment_reply: true,
          issue: %Issue{
            id: issue_id,
            identifier: "MT-565",
            state: "In Review",
            latest_comment_id: "comment-1"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      state: "In Review",
      title: "Review comment",
      latest_comment_id: "comment-1",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert Process.alive?(agent_pid)
    assert updated_entry.issue.state == "In Review"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "stale retry dispatch releases claim when issue refresh skips" do
    issue_id = "issue-stale-dispatch"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      title: "Refresh moved out of active state",
      state: "In Progress",
      description: "Dispatch should not leave the issue claimed.",
      labels: []
    }

    issue_fetcher = fn [^issue_id] ->
      {:ok, [%Issue{issue | state: "In Review"}]}
    end

    updated_state = Orchestrator.dispatch_issue_for_test(state, issue, issue_fetcher)

    refute MapSet.member?(updated_state.claimed, issue_id)
    assert updated_state.running == %{}
    assert updated_state.retry_attempts == %{}
  end

  test "comment reply dispatch only runs for unseen latest comments" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_comment_reply_states: ["In Review"],
      tracker_terminal_states: ["Done"],
      max_concurrent_agents: 2
    )

    old_issue = %Issue{
      id: "issue-comment-old",
      identifier: "MT-563",
      title: "Already seen comment",
      state: "In Review",
      latest_comment_id: "comment-1"
    }

    new_issue = %Issue{
      id: "issue-comment-new",
      identifier: "MT-564",
      title: "New review comment",
      state: "In Review",
      latest_comment_id: "comment-2"
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      comment_reply_seen: Orchestrator.comment_reply_seen_snapshot_for_test([old_issue]),
      max_concurrent_agents: 2
    }

    refute Orchestrator.should_dispatch_comment_reply_issue_for_test(old_issue, state)
    assert Orchestrator.should_dispatch_comment_reply_issue_for_test(new_issue, state)
  end

  test "snapshot exposes built-in comment monitor role" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_comment_reply_states: ["Backlog", "Todo", "In Progress", "Merging", "Rework", "Waiting", "In Review"]
    )

    orchestrator_name = Module.concat(__MODULE__, :CommentMonitorSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    snapshot = GenServer.call(pid, :snapshot)
    role = Enum.find(snapshot.agent_roles, &(&1.name == "linear_comment_monitor"))

    assert role.enabled == true
    assert role.status == "idle"
    assert role.command == "builtin:linear-comment-monitor"
    assert role.metadata.states == ["Backlog", "Todo", "In Progress", "Merging", "Rework", "Waiting", "In Review"]
  end

  test "snapshot exposes built-in waiting blocker role" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_waiting_state: "Waiting")

    orchestrator_name = Module.concat(__MODULE__, :WaitingBlockerSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    snapshot = GenServer.call(pid, :snapshot)
    role = Enum.find(snapshot.agent_roles, &(&1.name == "waiting_blocker_audit"))

    assert role.enabled == true
    assert role.status == "idle"
    assert role.command == "builtin:waiting-blocker-monitor"
    assert role.metadata.waiting_state == "Waiting"
  end

  test "normal dispatch preserves a slot when a comment reply is pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo"],
      tracker_comment_reply_states: ["In Review"],
      tracker_terminal_states: ["Done"],
      max_concurrent_agents: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-running" => %{
          issue: %Issue{id: "issue-running", identifier: "MT-568", state: "Todo"},
          identifier: "MT-568"
        }
      },
      claimed: MapSet.new(["issue-running"]),
      comment_reply_seen: %{},
      comment_reply_reserve_active: true,
      max_concurrent_agents: 2
    }

    normal_issue = %Issue{id: "issue-normal", identifier: "MT-569", title: "Normal issue", state: "Todo"}

    reply_issue = %Issue{
      id: "issue-reply",
      identifier: "MT-570",
      state: "In Review",
      latest_comment_id: "comment-1"
    }

    refute Orchestrator.should_dispatch_issue_for_test(normal_issue, state)
    assert Orchestrator.should_dispatch_comment_reply_issue_for_test(reply_issue, state)
  end

  test "normal dispatch uses the last slot when no comment reply is pending" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo"],
      tracker_comment_reply_states: ["In Review"],
      tracker_terminal_states: ["Done"],
      max_concurrent_agents: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-running" => %{
          issue: %Issue{id: "issue-running", identifier: "MT-573", state: "Todo"},
          identifier: "MT-573"
        }
      },
      claimed: MapSet.new(["issue-running"]),
      comment_reply_seen: %{},
      comment_reply_reserve_active: false,
      max_concurrent_agents: 2
    }

    normal_issue = %Issue{id: "issue-normal", identifier: "MT-574", title: "Normal issue", state: "Todo"}

    assert Orchestrator.should_dispatch_issue_for_test(normal_issue, state)
  end

  test "normal dispatch uses the last slot when comment replies are disabled" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo"],
      tracker_comment_reply_states: [],
      tracker_terminal_states: ["Done"],
      max_concurrent_agents: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-running" => %{
          issue: %Issue{id: "issue-running", identifier: "MT-571", state: "Todo"},
          identifier: "MT-571"
        }
      },
      claimed: MapSet.new(["issue-running"]),
      max_concurrent_agents: 2
    }

    normal_issue = %Issue{id: "issue-normal", identifier: "MT-572", title: "Normal issue", state: "Todo"}

    assert Orchestrator.should_dispatch_issue_for_test(normal_issue, state)
  end

  test "comment reply completion records latest comment as seen" do
    issue_id = "issue-comment-complete"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CommentReplyCompleteOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-566",
      comment_reply: true,
      issue: %Issue{
        id: issue_id,
        identifier: "MT-566",
        state: "In Review",
        latest_comment_id: "comment-1"
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:comment_reply_seen, %{})
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert state.comment_reply_seen[issue_id] == "comment-1"
  end

  test "failed comment reply leaves latest comment unseen for retry" do
    issue_id = "issue-comment-failed"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CommentReplyFailedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-567",
      comment_reply: true,
      issue: %Issue{
        id: issue_id,
        identifier: "MT-567",
        state: "In Review",
        latest_comment_id: "comment-1"
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:comment_reply_seen, %{})
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.comment_reply_seen, issue_id)
  end

  test "blocked comment reply records latest comment as seen" do
    write_workflow_file!(Workflow.workflow_file_path(), max_turn_tokens: 100)

    issue_id = "issue-comment-token-block"
    orchestrator_name = Module.concat(__MODULE__, :CommentReplyTokenBlockOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-568",
      state: "In Review",
      url: "https://example.org/issues/MT-568",
      latest_comment_id: "comment-1"
    }

    running_entry = %{
      identifier: "MT-568",
      comment_reply: true,
      issue: issue,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:comment_reply_seen, %{})
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:codex_worker_update, issue_id, token_count_update(101)})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert state.comment_reply_seen[issue_id] == "comment-1"
    assert Map.has_key?(state.blocked, issue_id)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, delay_type: :continuation, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
  end

  test "scope-audit parked worker exit releases claim without continuation retry" do
    issue_id = "issue-scope-audit-parked"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ScopeAuditParkedExitOrchestrator)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "Rework"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:worker_result_info, issue_id, :scope_audit_parked})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "normal worker exit with cloud gate marker schedules cooldown retry" do
    issue_id = "issue-cloud-gate"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CloudGateRetryOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(), cloud_gate_retry_cooldown_ms: 60_000)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    workspace = Path.join(System.tmp_dir!(), "symphony-cloud-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "busy\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-573",
      issue: %Issue{id: issue_id, identifier: "MT-573", state: "Rework"},
      started_at: DateTime.utc_now(),
      workspace_path: workspace
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, delay_type: :cloud_gate, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
  end

  test "normal worker exit with local bench gate marker schedules cooldown retry" do
    issue_id = "issue-local-bench-gate"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LocalBenchGateRetryOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(), local_bench_gate_retry_cooldown_ms: 120_000)

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    workspace =
      Path.join(System.tmp_dir!(), "symphony-local-bench-gate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join([workspace, ".symphony", "local-bench-gate-blocked"]), "busy\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-574",
      issue: %Issue{id: issue_id, identifier: "MT-574", state: "Rework"},
      started_at: DateTime.utc_now(),
      workspace_path: workspace
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, delay_type: :local_bench_gate, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
  end

  test "resource gate retry delays use configured cooldowns" do
    write_workflow_file!(Workflow.workflow_file_path(),
      cloud_gate_retry_cooldown_ms: 12_345,
      local_bench_gate_retry_cooldown_ms: 2_345
    )

    assert Orchestrator.retry_delay_for_test(1, %{delay_type: :cloud_gate}) == 12_345
    assert Orchestrator.retry_delay_for_test(2, %{delay_type: "cloud_gate"}) == 12_345
    assert Orchestrator.retry_delay_for_test(1, %{delay_type: :local_bench_gate}) == 2_345
    assert Orchestrator.retry_delay_for_test(2, %{delay_type: "local_bench_gate"}) == 2_345
    assert Orchestrator.retry_delay_for_test(1, %{delay_type: :continuation}) == 1_000
  end

  test "resource-gated slot waits use immediate retry delay" do
    write_workflow_file!(Workflow.workflow_file_path(), cloud_gate_retry_cooldown_ms: 60_000)

    assert Orchestrator.retry_delay_for_test(3, %{
             delay_type: :cloud_gate,
             retry_delay_ms: 1_000
           }) == 1_000

    assert Orchestrator.retry_delay_for_test(3, %{delay_type: :cloud_gate}) == 60_000
  end

  test "linear rate limits back off poll loop and retry polls until reset" do
    state = %Orchestrator.State{poll_interval_ms: 5_000}

    assert Orchestrator.poll_backoff_delay_for_test(state, {:linear_rate_limited, 120_000}) == 121_000
    assert Orchestrator.poll_backoff_delay_for_test(state, {:linear_rate_limited, 500}) == 5_000
    refute Orchestrator.poll_backoff_delay_for_test(state, {:linear_api_status, 400})

    metadata =
      Orchestrator.retry_poll_failure_metadata_for_test(
        %{delay_type: :cloud_gate},
        {:linear_rate_limited, 120_000}
      )

    assert metadata.error == "retry poll failed: {:linear_rate_limited, 120000}"
    assert metadata.retry_delay_ms == 121_000
    assert Orchestrator.retry_delay_for_test(9, metadata) == 121_000
  end

  test "retry refresh polls only the retried issue by id" do
    issue_id = "issue-retry-by-id"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Rework"],
      tracker_terminal_states: ["Done"]
    )

    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, RetryLinearClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    Process.put(
      {RetryLinearClient, :issues},
      [%Issue{id: issue_id, identifier: "MT-700", state: "Done"}]
    )

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      max_concurrent_agents: 1
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{identifier: "MT-700"})

    assert_receive {:retry_fetch_issue_states_by_ids, [^issue_id]}
    refute_receive :retry_fetch_candidate_issues
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry capacity errors identify reserved comment reply slots" do
    issue_id = "issue-retry-reserved"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Rework"],
      max_concurrent_agents: 2
    )

    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, RetryLinearClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    state = %Orchestrator.State{
      running: %{"issue-running" => %{}},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      max_concurrent_agents: 2,
      comment_reply_reserve_active: true
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{identifier: "MT-702"})

    refute_receive {:retry_fetch_issue_states_by_ids, _ids}

    assert %{attempt: 2, error: "no dispatchable agent slots; reserved for comment replies"} =
             retry = updated_state.retry_attempts[issue_id]

    Process.cancel_timer(retry.timer_ref)
  end

  test "resource-gated retries stay local while marker is still busy" do
    issue_id = "issue-local-gate-retry"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Rework"],
      cloud_gate_retry_cooldown_ms: 60_000
    )

    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, RetryLinearClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    workspace =
      Path.join(System.tmp_dir!(), "symphony-busy-cloud-gate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    lock_path = Path.join(workspace, "deploy.lock")
    File.write!(lock_path, "busy\n")
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "lock=#{lock_path}\n")

    on_exit(fn -> File.rm_rf(workspace) end)

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      max_concurrent_agents: 1
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_retry_issue_for_test(state, issue_id, 1, %{
               identifier: "MT-701",
               delay_type: :cloud_gate,
               workspace_path: workspace
             })

    refute_receive {:retry_fetch_issue_states_by_ids, _ids}
    refute_receive :retry_fetch_candidate_issues

    assert %{attempt: 2, error: "cloud gate busy", delay_type: :cloud_gate} =
             updated_state.retry_attempts[issue_id]
  end

  test "resource-gated retries yield slots to other runnable issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Rework"],
      tracker_terminal_states: ["Done"],
      tracker_comment_reply_states: [],
      max_concurrent_agents: 2
    )

    gated_issue = %Issue{
      id: "issue-cloud-gated",
      identifier: "MT-575",
      title: "Cloud gated retry",
      state: "Rework"
    }

    runnable_issue = %Issue{
      id: "issue-runnable",
      identifier: "MT-576",
      title: "Runnable local work",
      state: "Rework"
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(["issue-cloud-gated"]),
      retry_attempts: %{},
      max_concurrent_agents: 2
    }

    assert Orchestrator.resource_gate_retry_should_yield_for_test?(
             [gated_issue, runnable_issue],
             gated_issue,
             state,
             %{delay_type: :cloud_gate}
           )

    refute Orchestrator.resource_gate_retry_should_yield_for_test?(
             [gated_issue, runnable_issue],
             gated_issue,
             state,
             %{delay_type: :continuation}
           )
  end

  test "released cloud gate retries wake early" do
    workspace = Path.join(System.tmp_dir!(), "symphony-cloud-gate-release-#{System.unique_integer([:positive])}")
    lock_dir = Path.join(System.tmp_dir!(), "symphony-cloud-gate-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(lock_dir)
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "lock=#{lock_dir}\n")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(lock_dir)
    end)

    stale_timer_ref = Process.send_after(self(), :stale_cloud_retry, 60_000)
    stale_retry_token = make_ref()

    state = %Orchestrator.State{
      retry_attempts: %{
        "issue-cloud-gate" => %{
          attempt: 1,
          timer_ref: stale_timer_ref,
          retry_token: stale_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          identifier: "MT-577",
          delay_type: :cloud_gate,
          workspace_path: workspace
        }
      }
    }

    state_with_lock = Orchestrator.wake_released_resource_gate_retries_for_test(state)
    assert state_with_lock.retry_attempts["issue-cloud-gate"].timer_ref == stale_timer_ref

    File.rm_rf!(lock_dir)

    state = Orchestrator.wake_released_resource_gate_retries_for_test(state_with_lock)
    retry = state.retry_attempts["issue-cloud-gate"]

    assert retry.timer_ref != stale_timer_ref
    assert retry.retry_token != stale_retry_token
    assert retry.error == "resource gate released; retrying soon"
    assert is_integer(retry.due_at_ms)

    Process.cancel_timer(retry.timer_ref)
  end

  test "released cloud gate retries preserve retry poll backoff" do
    workspace = Path.join(System.tmp_dir!(), "symphony-cloud-gate-poll-backoff-#{System.unique_integer([:positive])}")
    lock_dir = Path.join(System.tmp_dir!(), "symphony-cloud-gate-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Path.join([workspace, ".symphony", "cloud-gate-blocked"]),
      "lock=#{lock_dir}\n"
    )

    on_exit(fn -> File.rm_rf(workspace) end)

    stale_timer_ref = Process.send_after(self(), :stale_cloud_retry, 60_000)
    stale_retry_token = make_ref()

    state = %Orchestrator.State{
      retry_attempts: %{
        "issue-cloud-gate" => %{
          attempt: 1,
          timer_ref: stale_timer_ref,
          retry_token: stale_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          identifier: "MT-577",
          delay_type: :cloud_gate,
          error: "retry poll failed: {:linear_api_status, 400}",
          workspace_path: workspace
        }
      }
    }

    state = Orchestrator.wake_released_resource_gate_retries_for_test(state)
    retry = state.retry_attempts["issue-cloud-gate"]

    assert retry.timer_ref == stale_timer_ref
    assert retry.retry_token == stale_retry_token

    Process.cancel_timer(stale_timer_ref)
  end

  test "resource-gated retry remains parked while its gate lock is live" do
    workspace = Path.join(System.tmp_dir!(), "symphony-cloud-gate-park-#{System.unique_integer([:positive])}")
    lock_dir = Path.join(System.tmp_dir!(), "symphony-cloud-gate-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(lock_dir)
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "lock=#{lock_dir}\n")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(lock_dir)
    end)

    assert Orchestrator.resource_gate_retry_still_blocked_for_test?(%{
             delay_type: :cloud_gate,
             workspace_path: workspace
           })

    File.rm_rf!(lock_dir)

    refute Orchestrator.resource_gate_retry_still_blocked_for_test?(%{
             delay_type: :cloud_gate,
             workspace_path: workspace
           })
  end

  test "parked resource-gated retry reschedules without crashing dispatcher" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-cloud-gate-retry-dispatch-#{System.unique_integer([:positive])}")

    lock_dir =
      Path.join(System.tmp_dir!(), "symphony-cloud-gate-retry-lock-#{System.unique_integer([:positive])}")

    issue = %Issue{
      id: "issue-cloud-gate",
      identifier: "MT-578",
      title: "Cloud gated retry",
      state: "Rework"
    }

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.mkdir_p!(lock_dir)
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "lock=#{lock_dir}\n")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(lock_dir)
    end)

    state = %Orchestrator.State{
      claimed: MapSet.new([issue.id]),
      max_concurrent_agents: 2
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_active_retry_for_test(
               state,
               issue,
               1,
               %{delay_type: :cloud_gate, workspace_path: workspace},
               [issue]
             )

    assert %{attempt: 2, error: "cloud gate busy"} = retry = updated_state.retry_attempts[issue.id]
    assert is_reference(retry.timer_ref)
    Process.cancel_timer(retry.timer_ref)
  end

  test "resource-gated retry remains parked while an async resource job is running" do
    workspace = Path.join(System.tmp_dir!(), "symphony-resource-job-park-#{System.unique_integer([:positive])}")
    status_path = Path.join(System.tmp_dir!(), "symphony-resource-job-status-#{System.unique_integer([:positive])}.env")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(status_path, "status=running\n")
    File.write!(Path.join([workspace, ".symphony", "cloud-gate-blocked"]), "status_path=#{status_path}\n")

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm(status_path)
    end)

    assert Orchestrator.resource_gate_retry_still_blocked_for_test?(%{
             delay_type: :cloud_gate,
             workspace_path: workspace
           })

    File.write!(status_path, "status=failed\nexit_code=1\n")

    refute Orchestrator.resource_gate_retry_still_blocked_for_test?(%{
             delay_type: :cloud_gate,
             workspace_path: workspace
           })
  end

  test "released local bench gate retries wake when a pool slot is free" do
    workspace =
      Path.join(System.tmp_dir!(), "symphony-local-bench-release-#{System.unique_integer([:positive])}")

    bench_base =
      Path.join(System.tmp_dir!(), "symphony-local-bench-base-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    for slot <- 1..3 do
      File.mkdir_p!(local_bench_lock_path_for_test(bench_base, slot))
    end

    File.write!(
      Path.join([workspace, ".symphony", "local-bench-gate-blocked"]),
      "base=#{bench_base}\nsize=3\n"
    )

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf("#{bench_base}.use.lock")
      File.rm_rf("#{bench_base}-2.use.lock")
      File.rm_rf("#{bench_base}-3.use.lock")
    end)

    stale_timer_ref = Process.send_after(self(), :stale_local_bench_retry, 60_000)
    stale_retry_token = make_ref()

    state = %Orchestrator.State{
      retry_attempts: %{
        "issue-local-bench-gate" => %{
          attempt: 1,
          timer_ref: stale_timer_ref,
          retry_token: stale_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 60_000,
          identifier: "MT-578",
          delay_type: :local_bench_gate,
          workspace_path: workspace
        }
      }
    }

    state_with_full_pool = Orchestrator.wake_released_resource_gate_retries_for_test(state)
    assert state_with_full_pool.retry_attempts["issue-local-bench-gate"].timer_ref == stale_timer_ref

    File.rm_rf!(local_bench_lock_path_for_test(bench_base, 2))

    state = Orchestrator.wake_released_resource_gate_retries_for_test(state_with_full_pool)
    retry = state.retry_attempts["issue-local-bench-gate"]

    assert retry.timer_ref != stale_timer_ref
    assert retry.retry_token != stale_retry_token
    assert retry.error == "resource gate released; retrying soon"
    assert is_integer(retry.due_at_ms)

    Process.cancel_timer(retry.timer_ref)
  end

  test "resource lock cleanup removes dead owner locks" do
    lock_dir = Path.join(System.tmp_dir!(), "symphony-dead-owner-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lock_dir)

    {dead_pid, 0} = System.cmd("sh", ["-c", "echo $$"])

    File.write!(
      Path.join(lock_dir, "owner"),
      "pid=#{String.trim(dead_pid)}\ntarget_issue=MT-579\nstarted_at=2026-05-08T00:00:00Z\n"
    )

    on_exit(fn -> File.rm_rf(lock_dir) end)

    state = %Orchestrator.State{running: %{}, retry_attempts: %{}}
    Orchestrator.cleanup_orphaned_resource_locks_for_test(state, [lock_dir])

    refute File.exists?(lock_dir)
  end

  test "resource lock cleanup preserves active owner locks" do
    lock_dir = Path.join(System.tmp_dir!(), "symphony-active-owner-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lock_dir)

    File.write!(
      Path.join(lock_dir, "owner"),
      "pid=#{System.pid()}\ntarget_issue=MT-580\nstarted_at=2026-05-08T00:00:00Z\n"
    )

    on_exit(fn -> File.rm_rf(lock_dir) end)

    state = %Orchestrator.State{
      running: %{"issue-active-owner" => %{identifier: "MT-580"}},
      retry_attempts: %{}
    }

    Orchestrator.cleanup_orphaned_resource_locks_for_test(state, [lock_dir])

    assert File.exists?(lock_dir)
  end

  test "resource lock cleanup preserves inactive live owner locks" do
    lock_dir = Path.join(System.tmp_dir!(), "symphony-inactive-live-owner-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(lock_dir)

    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        args: ["-c", "exec -a resource_lock_holder.sh sleep 60"]
      ])

    {:os_pid, owner_pid} = Port.info(port, :os_pid)

    File.write!(
      Path.join(lock_dir, "owner"),
      "pid=#{owner_pid}\ntarget_issue=MT-580A\nstarted_at=2026-05-08T00:00:00Z\n"
    )

    File.touch!(lock_dir, {{2020, 1, 1}, {0, 0, 0}})

    on_exit(fn ->
      if Port.info(port) do
        Port.close(port)
      end

      System.cmd("kill", ["-TERM", Integer.to_string(owner_pid)], stderr_to_stdout: true)
      File.rm_rf(lock_dir)
    end)

    state = %Orchestrator.State{running: %{}, retry_attempts: %{}}

    Orchestrator.cleanup_orphaned_resource_locks_for_test(state, [lock_dir])

    assert File.exists?(lock_dir)
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(owner_pid)], stderr_to_stdout: true)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms - 2_000
    assert remaining_ms <= max_remaining_ms
  end

  defp local_bench_lock_path_for_test(base, 1), do: "#{base}.use.lock"
  defp local_bench_lock_path_for_test(base, slot), do: "#{base}-#{slot}.use.lock"

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue, phase, and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} phase={{ phase }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "phase=execution"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder derives prompt phase from issue state" do
    assert PromptBuilder.phase_for_issue(%{state: "Backlog"}) == "idle"
    assert PromptBuilder.phase_for_issue(%{state: "Done"}) == "terminal"
    assert PromptBuilder.phase_for_issue(%{"state" => "Human Review"}) == "review"
    assert PromptBuilder.phase_for_issue(%{state: "Merging"}) == "landing"
    assert PromptBuilder.phase_for_issue(%{state: "Rework"}) == "rework"
    assert PromptBuilder.phase_for_issue(%{state: "In Progress"}) == "execution"
    assert PromptBuilder.phase_for_issue(%{state: nil}) == "execution"
    assert PromptBuilder.phase_for_issue(%{}) == "execution"
    assert PromptBuilder.phase_for_issue(%{state: "In Progress"}, comment_reply: true) == "comment_reply"
    assert PromptBuilder.phase_for_issue(%{state: "In Review"}, comment_reply: true) == "comment_reply"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on Linear ticket `MT-616`"
    assert prompt =~ "for Symphony (`symphony`)"
    assert prompt =~ "Prompt phase: `execution`"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is unattended orchestration."
    assert prompt =~ "Keep final replies to completed actions and blockers only."
    assert prompt =~ "## Execution Packet"
    assert prompt =~ "Clarification is allowed only by parking the issue"
    assert prompt =~ "Existing workpad acceptance criteria are evidence, not authority."
    assert prompt =~ "Scope Confidence Gate:"
    assert prompt =~ "move the issue to `Waiting`"
    assert prompt =~ "### Scope Confidence"
    assert prompt =~ "Review feedback sweep before `Human Review`"
    assert prompt =~ "requires no reviewer setup"
    assert prompt =~ "developmentBranchReviewed: true"
    assert prompt =~ "sharedBranchCommitted: true"
    assert prompt =~ "targetContainsSharedBranchCommit: true"
    assert prompt =~ "reviewRecipeAccessible: true"
    refute prompt =~ "## Landing Packet"
    refute prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "Retry attempt #2"
  end

  test "in-repo WORKFLOW.md gates landing instructions to merging phase" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-617",
      title: "Land approved PR",
      description: "Merge the approved work",
      state: "Merging",
      url: "https://example.org/issues/MT-617/land-approved-pr",
      labels: ["merge"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Prompt phase: `landing`"
    assert prompt =~ "## Landing Packet"
    assert prompt =~ "Open `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    refute prompt =~ "## Execution Packet"
    refute prompt =~ "Review feedback sweep before `Human Review`"
  end

  test "in-repo WORKFLOW.md renders focused comment reply packet" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-618",
      title: "Repair review recipe",
      description: "The review recipe points at a PR instead of the app.",
      state: "In Review",
      url: "https://example.org/issues/MT-618/repair-review-recipe",
      labels: ["review"],
      latest_comment_body: "Please rewrite the Demo / Review Recipe so it demos runtime behavior."
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, comment_reply: true)

    assert prompt =~ "Prompt phase: `comment_reply`"
    assert prompt =~ "## Comment Reply Packet"
    assert prompt =~ "update the one active `## Codex Workpad`"
    assert prompt =~ "rewrite `Demo / Review Recipe`"
    assert prompt =~ "exact reviewer-reachable app/runtime/API/dashboard URL"
    assert prompt =~ "move the issue to `Rework`"
    refute prompt =~ "move the issue to `Waiting` instead of guessing"
    refute prompt =~ "## Execution Packet"
    refute prompt =~ "Run the Scope Confidence Gate"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "blocked scope audit parks issue before implementation starts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-scope-audit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_waiting_state: "Waiting",
        workspace_root: workspace_root,
        hook_before_run: "touch before-run-ran",
        codex_command: "/bin/false app-server",
        scope_audit: %{enabled: true}
      )

      issue = %Issue{
        id: "issue-scope-audit",
        identifier: "MT-560",
        title: "Ambiguous asset generation",
        description: "Generate missing assets, but target surface is unclear.",
        state: "Rework",
        url: "https://example.org/issues/MT-560",
        labels: []
      }

      audit_runner = fn _issue, _workspace, _recipient, _opts ->
        {:ok,
         %SymphonyElixir.ScopeAudit.Result{
           verdict: :blocked,
           summary: "Ticket could mean generated media or deterministic fallbacks.",
           intended_workflow: "Tenant asks an agent to generate or replace missing assets.",
           target_surfaces: "blocked",
           acceptance_source: "ticket body only",
           evidence: ["No target module list is present."],
           confusions: ["Which modules and asset slots are in scope?"]
         }}
      end

      assert :ok = AgentRunner.run(issue, nil, scope_audit_runner: audit_runner)

      assert_receive {:memory_tracker_comment, "issue-scope-audit", body}, 500
      assert body =~ "## Codex Workpad"
      assert body =~ "Verdict: `blocked`"
      assert body =~ "Which modules and asset slots are in scope?"

      assert_receive {:memory_tracker_state_update, "issue-scope-audit", "Waiting"}, 500

      workspace = Path.join(workspace_root, "MT-560")
      refute File.exists?(Path.join(workspace, "before-run-ran"))
    after
      File.rm_rf(test_root)
    end
  end

  test "in-progress continuations skip scope audit preflight" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-in-progress-skip-audit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      audit_binary = Path.join(test_root, "fake-scope-audit")
      audit_trace = Path.join(test_root, "fake-scope-audit.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-in-progress-skip\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-in-progress-skip\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      File.write!(audit_binary, """
      #!/bin/sh
      printf 'scope audit invoked\\n' > "#{audit_trace}"
      exit 1
      """)

      File.chmod!(audit_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_waiting_state: "Waiting",
        workspace_root: workspace_root,
        hook_before_run: "touch before-run-ran",
        codex_command: "#{codex_binary} app-server",
        scope_audit: %{enabled: true, command: "#{audit_binary} app-server"}
      )

      issue = %Issue{
        id: "issue-in-progress-skip-audit",
        identifier: "MT-563",
        title: "Continue analytics implementation",
        description: "Broad ticket body that would be ambiguous for a fresh start.",
        state: "In Progress",
        url: "https://example.org/issues/MT-563",
        labels: [],
        active_workpad_body: "## Codex Workpad\n\nContinue from current implementation state."
      }

      assert :ok =
               AgentRunner.run(issue, self(),
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-in-progress-skip-audit"] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end
               )

      workspace = Path.join(workspace_root, "MT-563")
      assert File.exists?(Path.join(workspace, "before-run-ran"))
      refute File.exists?(audit_trace)
      refute_receive {:memory_tracker_state_update, "issue-in-progress-skip-audit", "Waiting"}, 300
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner claims rework issues before codex work" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-rework-claim-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-rework-claim\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-rework-claim\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_assignee: "me",
        workspace_root: workspace_root,
        hook_before_run: "touch before-run-ran",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-rework-claim",
        identifier: "MT-562",
        title: "Rework analytics implementation",
        description: "Fix the previous attempt.",
        state: "Rework",
        url: "https://example.org/issues/MT-562",
        labels: []
      }

      assert :ok =
               AgentRunner.run(issue, self(),
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-rework-claim"] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end
               )

      assert_receive {:memory_tracker_assignee_update, "issue-rework-claim", "me"}, 500
      assert_receive {:memory_tracker_state_update, "issue-rework-claim", "In Progress"}, 500

      assert_receive {:codex_worker_update, "issue-rework-claim", %{event: :prompt_prepared, payload: %{phase: "rework"}}},
                     500

      workspace = Path.join(workspace_root, "MT-562")
      assert File.exists?(Path.join(workspace, "before-run-ran"))
    after
      File.rm_rf(test_root)
    end
  end

  test "review-demo scope audit blockers continue into rework agent" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-demo-rework-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-review-demo\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-review-demo\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_waiting_state: "Waiting",
        workspace_root: workspace_root,
        hook_before_run: "touch before-run-ran",
        codex_command: "#{codex_binary} app-server",
        scope_audit: %{enabled: true}
      )

      issue = %Issue{
        id: "issue-review-demo-rework",
        identifier: "MT-561",
        title: "Repair analytics review recipe",
        description: "Review recipe points at a PR instead of a reviewer-ready app demo.",
        state: "Rework",
        url: "https://example.org/issues/MT-561",
        labels: []
      }

      audit_runner = fn _issue, _workspace, _recipient, _opts ->
        {:ok,
         %SymphonyElixir.ScopeAudit.Result{
           verdict: :blocked,
           summary: "Review recipe points at a PR and lacks a no-setup app demo URL.",
           intended_workflow: "Normal agent repairs the Demo / Review Recipe from repo evidence.",
           target_surfaces: "Demo / Review Recipe",
           acceptance_source: "active workpad",
           evidence: ["Open target is a pull request, not the app."],
           confusions: ["Missing exact no-setup Open: URL for the review demo."]
         }}
      end

      assert :ok =
               AgentRunner.run(issue, self(),
                 max_turns: 1,
                 scope_audit_runner: audit_runner,
                 issue_state_fetcher: fn ["issue-review-demo-rework"] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end
               )

      workspace = Path.join(workspace_root, "MT-561")
      assert File.exists?(Path.join(workspace, "before-run-ran"))
      refute_receive {:memory_tracker_state_update, "issue-review-demo-rework", "Waiting"}, 300
      refute_receive {:memory_tracker_comment, "issue-review-demo-rework", _body}, 300
    after
      File.rm_rf(test_root)
    end
  end

  test "review-demo rework context skips scope audit preflight" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-demo-skip-audit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      audit_binary = Path.join(test_root, "fake-scope-audit")
      audit_trace = Path.join(test_root, "fake-scope-audit.trace")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-review-demo-skip\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-review-demo-skip\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      File.write!(audit_binary, """
      #!/bin/sh
      printf 'scope audit invoked\\n' > "#{audit_trace}"
      exit 1
      """)

      File.chmod!(audit_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_waiting_state: "Waiting",
        workspace_root: workspace_root,
        hook_before_run: "touch before-run-ran",
        codex_command: "#{codex_binary} app-server",
        scope_audit: %{enabled: true, command: "#{audit_binary} app-server"}
      )

      issue = %Issue{
        id: "issue-review-demo-skip-audit",
        identifier: "MT-562",
        title: "Core Traffic & Behavior Analytics Pipeline",
        description: "Build the foundational analytics system for traffic sources, devices, sessions, cart abandonment, and below-the-fold engagement.",
        state: "Rework",
        url: "https://example.org/issues/MT-562",
        labels: [],
        latest_comment_body:
          "Final process fix from live proof: scope audit was still relitigating the original broad ticket instead of recognizing this Rework pass is review/demo recipe repair. Symphony now skips scope audit when the active Rework context is review/demo repair, so the normal agent can inspect repo/workpad and repair the demo path. Re-queued in Rework.",
        active_workpad_body: """
        ## Codex Workpad

        ### Status
        Waiting on scope audit.

        ### Confusions
        - Is this backend pipeline only, or does it also include frontend event instrumentation?
        - Which exact source(s) of truth and consumer surface(s) are in scope for v1?
        """
      }

      assert :ok =
               AgentRunner.run(issue, self(),
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-review-demo-skip-audit"] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end
               )

      workspace = Path.join(workspace_root, "MT-562")
      assert File.exists?(Path.join(workspace, "before-run-ran"))
      refute File.exists?(audit_trace)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :prompt_prepared,
                        timestamp: %DateTime{},
                        payload: %{
                          phase: "execution",
                          turn_number: 1,
                          max_turns: 20,
                          prompt_bytes: prompt_bytes,
                          prompt_words: prompt_words
                        }
                      }},
                     500

      assert prompt_bytes > 0
      assert prompt_words > 0

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner returns to orchestrator when cloud gate marker appears after a turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-cloud-gate-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cloud-gate"}}}'
            ;;
          4)
            mkdir -p .symphony
            printf 'cloud auth unavailable\\n' > .symphony/cloud-gate-blocked
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cloud-gate-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cloud-gate-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        send(parent, :unexpected_issue_state_fetch)

        {:ok,
         [
           %Issue{
             id: "issue-cloud-gate-runner",
             identifier: "MT-249",
             title: "Stop on cloud gate",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-cloud-gate-runner",
        identifier: "MT-249",
        title: "Stop on cloud gate",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive :unexpected_issue_state_fetch, 50

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1

      assert File.read!(Path.join([workspace_root, "MT-249", ".symphony", "cloud-gate-blocked"])) =~
               "cloud auth unavailable"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp token_count_update(total_tokens) do
    %{
      event: :token_count,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "payload" => %{
              "info" => %{
                "total_token_usage" => %{
                  "input_tokens" => total_tokens,
                  "output_tokens" => 0,
                  "total_tokens" => total_tokens
                }
              }
            }
          }
        }
      }
    }
  end
end
