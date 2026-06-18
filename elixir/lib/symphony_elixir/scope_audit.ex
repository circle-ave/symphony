defmodule SymphonyElixir.ScopeAudit do
  @moduledoc """
  Runs a clarification preflight before implementation starts.
  """

  require Logger

  alias SymphonyElixir.Codex.{AppServer, MessageText}
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker}

  @read_only_turn_sandbox %{
    "type" => "readOnly",
    "networkAccess" => true
  }

  defmodule Result do
    @moduledoc false

    @type verdict :: :clear | :blocked
    @type t :: %__MODULE__{
            verdict: verdict(),
            summary: String.t() | nil,
            intended_workflow: String.t() | nil,
            target_surfaces: String.t() | nil,
            acceptance_source: String.t() | nil,
            evidence: [String.t()],
            confusions: [String.t()]
          }

    defstruct [
      :verdict,
      :summary,
      :intended_workflow,
      :target_surfaces,
      :acceptance_source,
      evidence: [],
      confusions: []
    ]
  end

  @type run_result :: {:ok, :disabled | Result.t()} | {:error, term()}

  @spec run(Issue.t(), Path.t(), pid() | nil, keyword()) :: run_result()
  def run(%Issue{} = issue, workspace, codex_update_recipient \\ nil, opts \\ [])
      when is_binary(workspace) do
    settings = Config.settings!()
    audit = settings.agent.scope_audit

    if audit_enabled?(audit, issue, opts) do
      do_run(issue, workspace, codex_update_recipient, opts, audit, settings)
    else
      {:ok, :disabled}
    end
  end

  @spec park_blocked_issue(Issue.t(), Result.t()) :: :ok | {:error, term()}
  def park_blocked_issue(%Issue{id: issue_id} = issue, %Result{verdict: :blocked} = result)
      when is_binary(issue_id) do
    case Config.settings!().tracker.waiting_state do
      waiting_state when is_binary(waiting_state) and waiting_state != "" ->
        case Tracker.create_comment(issue_id, blocked_workpad(issue, result), identity: :scope_audit) do
          :ok -> Tracker.update_issue_state(issue_id, waiting_state)
          error -> error
        end

      _ ->
        {:error, :missing_waiting_state}
    end
  end

  def park_blocked_issue(%Issue{}, %Result{}), do: {:error, :scope_audit_not_blocked}
  def park_blocked_issue(_issue, _result), do: {:error, :invalid_scope_audit_result}

  @spec reworkable_review_recipe_blocker?(Result.t()) :: boolean()
  def reworkable_review_recipe_blocker?(%Result{verdict: :blocked} = result) do
    result
    |> result_text()
    |> review_recipe_repair_text?()
  end

  def reworkable_review_recipe_blocker?(%Result{}), do: false

  @spec reworkable_review_recipe_context?(Issue.t()) :: boolean()
  def reworkable_review_recipe_context?(%Issue{} = issue) do
    issue
    |> issue_context_text()
    |> review_recipe_repair_text?()
  end

  defp do_run(issue, workspace, codex_update_recipient, opts, audit, settings) do
    prompt = audit_prompt(issue, audit)

    emit_audit_update(codex_update_recipient, issue, %{
      event: :scope_audit_prepared,
      timestamp: DateTime.utc_now(),
      payload: %{
        prompt_bytes: byte_size(prompt),
        prompt_words: word_count(prompt),
        timeout_ms: audit.timeout_ms
      }
    })

    session_opts = [
      command: audit_command(audit, settings),
      worker_host: Keyword.get(opts, :worker_host),
      approval_policy: "never",
      dynamic_tools: [],
      turn_sandbox_policy: @read_only_turn_sandbox
    ]

    run_audit_session(workspace, session_opts, prompt, issue, codex_update_recipient, audit)
  end

  defp run_audit_session(workspace, session_opts, prompt, issue, codex_update_recipient, audit) do
    parent = self()
    message_ref = make_ref()

    on_message = fn message ->
      send(parent, {message_ref, message})
      emit_audit_update(codex_update_recipient, issue, message)
    end

    task =
      async_audit_task(fn ->
        with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
          try do
            AppServer.run_turn(session, prompt, issue,
              on_message: on_message,
              tool_executor: &reject_dynamic_tool/2
            )
          after
            AppServer.stop_session(session)
          end
        end
      end)

    await_audit_result(task, task_monitor_ref(task), message_ref, [], audit.timeout_ms)
  end

  defp async_audit_task(fun) when is_function(fun, 0) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      nil -> Task.async(fun)
      _task_supervisor -> Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fun)
    end
  end

  defp await_audit_result(task, task_ref, message_ref, messages, timeout_ms) do
    receive do
      {^message_ref, message} ->
        await_audit_result(task, task_ref, message_ref, [message | messages], timeout_ms)

      {^task_ref, {:ok, _turn_session}} ->
        finish_audit_task(task)
        messages |> Enum.reverse() |> decode_result()

      {^task_ref, {:error, reason}} ->
        finish_audit_task(task)
        {:error, reason}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {:error, {:scope_audit_task_down, reason}}
    after
      timeout_ms ->
        stop_audit_task(task)
        {:error, :scope_audit_timeout}
    end
  end

  defp stop_audit_task(task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp finish_audit_task(task) do
    Task.shutdown(task, 0)
    :ok
  end

  defp task_monitor_ref(task), do: Map.fetch!(task, :ref)

  defp decode_result(messages) do
    messages
    |> MessageText.output()
    |> decode_result_text()
  end

  defp decode_result_text(output) when is_binary(output) do
    with {:ok, decoded} <- decode_json_object(output),
         {:ok, verdict} <- verdict(decoded) do
      {:ok,
       %Result{
         verdict: verdict,
         summary: string_value(decoded, "summary"),
         intended_workflow: string_value(decoded, "intended_workflow"),
         target_surfaces: string_value(decoded, "target_surfaces"),
         acceptance_source: string_value(decoded, "acceptance_source"),
         evidence: string_list(decoded, "evidence"),
         confusions: string_list(decoded, "confusions")
       }}
    end
  end

  defp decode_json_object(output) do
    output
    |> json_candidates()
    |> Enum.find_value(fn candidate ->
      case Jason.decode(candidate) do
        {:ok, %{} = decoded} -> {:ok, decoded}
        _ -> nil
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      nil -> {:error, :scope_audit_no_json}
    end
  end

  defp json_candidates(output) when is_binary(output) do
    trimmed = String.trim(output)
    fenced = Regex.scan(~r/```(?:json)?\s*(\{.*?\})\s*```/s, output, capture: :all_but_first)

    [
      [trimmed],
      List.flatten(fenced),
      json_object_slice(trimmed),
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.starts_with?(&1, "{") and String.ends_with?(&1, "}")))
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp json_object_slice(output) do
    with {start, _} <- :binary.match(output, "{"),
         {last_start, _} <- output |> :binary.matches("}") |> List.last() do
      [String.slice(output, start, last_start - start + 1)]
    else
      _ -> []
    end
  end

  defp verdict(decoded) do
    case string_value(decoded, "verdict") do
      "clear" -> {:ok, :clear}
      "blocked" -> {:ok, :blocked}
      _ -> {:error, :scope_audit_invalid_verdict}
    end
  end

  defp blocked_workpad(%Issue{} = issue, %Result{} = result) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    confusions = markdown_list(result.confusions, "- Define the missing scope, target surface, or acceptance criteria.")
    evidence = markdown_list(result.evidence, "- Scope audit used the ticket body, latest actionable comment, and linked artifact references available in the issue snapshot.")

    """
    ## Codex Workpad

    ### Plan
    - [x] 1. Run scope audit before implementation.
    - [x] 2. Park in Waiting because implementation scope is not clear enough to start.

    ### Scope Confidence
    - Verdict: `blocked`
    - Intended workflow: #{fallback(result.intended_workflow)}
    - Target surfaces/modules: #{fallback(result.target_surfaces)}
    - Acceptance source: #{fallback(result.acceptance_source)}

    ### Acceptance Criteria
    - [ ] Resolve the scope questions below before implementation starts.

    ### Validation
    - [x] Bounded scope audit completed before code changes.
    - [ ] Targeted tests: not run; blocked before implementation.

    ### Notes
    - #{timestamp}: Scope audit parked #{issue.identifier || issue.id} before implementation. #{fallback(result.summary)}

    ### Evidence
    #{evidence}

    ### Confusions
    #{confusions}
    """
  end

  defp markdown_list([], fallback_line), do: fallback_line

  defp markdown_list(items, _fallback_line) do
    Enum.map_join(items, "\n", fn item -> "- #{item}" end)
  end

  defp fallback(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "`blocked`"
      text -> text
    end
  end

  defp fallback(_value), do: "`blocked`"

  defp reject_dynamic_tool(tool, _arguments) do
    %{
      "success" => false,
      "output" => "Scope audit is read-only; dynamic tool #{inspect(tool)} is unavailable."
    }
  end

  defp audit_enabled?(audit, %Issue{} = issue, opts) do
    phase = PromptBuilder.phase_for_issue(issue)

    audit.enabled == true and
      Keyword.get(opts, :comment_reply, false) == false and
      phase in ["execution", "rework"] and
      not (phase == "rework" and reworkable_review_recipe_context?(issue))
  end

  defp audit_command(audit, settings) do
    case audit.command do
      command when is_binary(command) and command != "" ->
        command

      _ ->
        router_command(settings.codex.model_router) || settings.codex.command
    end
  end

  defp router_command(%{} = router_config) do
    map_get(router_config, "router_command") || map_get(router_config, "command")
  end

  defp router_command(_router_config), do: nil

  defp audit_prompt(%Issue{} = issue, _audit) do
    links =
      [issue.description, issue.latest_comment_body]
      |> Enum.flat_map(&linked_urls/1)
      |> Enum.uniq()
      |> Enum.take(8)

    """
    You are Symphony's scope-audit preflight.

    Decide whether implementation is clear enough to start. This is not the implementation turn.

    Hard rules:
    - Return JSON only.
    - Do not edit files, run tests, create branches, open PRs, or change Linear.
    - Use only the ticket body, latest active human comment, and directly linked artifacts.
    - If inspecting links is available, inspect only metadata or short summaries. Do not read full raw diffs, logs, build output, or broad repository files.
    - If the ticket supports materially different product definitions, target surfaces/modules are unclear, or acceptance cannot be verified, return `blocked`.
    - Missing or non-reviewable demo/review recipe details are agent-reworkable; return `clear` unless underlying product scope, target surfaces, or acceptance behavior is ambiguous.
    - If blocked, ask the fewest concrete questions needed to unblock implementation.
    Return exactly one JSON object:
    {
      "verdict": "clear | blocked",
      "summary": "short rationale",
      "intended_workflow": "who does what and where",
      "target_surfaces": "specific surfaces/modules, or blocked",
      "acceptance_source": "ticket/comment/artifact evidence",
      "evidence": ["short evidence item"],
      "confusions": ["question if blocked"]
    }

    Issue:
    - Identifier: #{issue.identifier}
    - Title: #{issue.title}
    - State: #{issue.state}
    - Labels: #{Enum.join(issue.labels || [], ", ")}
    - URL: #{issue.url}

    Description:
    #{issue.description || "No description provided."}

    Latest active human comment:
    #{latest_comment_text(issue)}

    Direct links:
    #{link_lines(links)}
    """
  end

  defp latest_comment_text(%Issue{latest_comment_body: body} = issue) when is_binary(body) do
    """
    Author: #{issue.latest_comment_user_name || issue.latest_comment_user_id || "unknown"}
    Created at: #{format_datetime(issue.latest_comment_created_at)}
    #{body}
    """
  end

  defp latest_comment_text(_issue), do: "None."

  defp result_text(%Result{} = result) do
    [
      result.summary,
      result.intended_workflow,
      result.target_surfaces,
      result.acceptance_source
    ]
    |> Kernel.++(result.evidence || [])
    |> Kernel.++(result.confusions || [])
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp issue_context_text(%Issue{} = issue) do
    [issue.latest_comment_body, issue.active_workpad_body]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp review_recipe_repair_text?(text) when is_binary(text) do
    review_recipe_context? =
      Enum.any?(
        [
          "review recipe",
          "demo recipe",
          "review/demo",
          "demo/review",
          "review demo",
          "demo path",
          "functional demo",
          "reviewer-accessible",
          "reviewer-reachable",
          "open:"
        ],
        &String.contains?(text, &1)
      )

    repair_signal? =
      Enum.any?(
        [
          "missing",
          "no setup",
          "no-setup",
          "url",
          "login",
          "credential",
          "localhost",
          "source diff",
          "pull request",
          "points at pr",
          "pr instead",
          "repair",
          "rework",
          "cannot be derived",
          "can be derived"
        ],
        &String.contains?(text, &1)
      )

    review_recipe_context? and repair_signal?
  end

  defp linked_urls(nil), do: []

  defp linked_urls(text) when is_binary(text) do
    ~r/https?:\/\/[^\s<>)\]]+/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".;,"))
  end

  defp link_lines([]), do: "- none"
  defp link_lines(links), do: Enum.map_join(links, "\n", fn link -> "- #{link}" end)

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_datetime), do: "unknown"

  defp emit_audit_update(recipient, %Issue{id: issue_id}, message)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp emit_audit_update(_recipient, _issue, _message), do: :ok

  defp string_value(map, key) when is_map(map) do
    case map_get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_list(map, key) when is_map(map) do
    case map_get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(12)

      value when is_binary(value) ->
        value
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(12)

      _ ->
        []
    end
  end

  defp word_count(prompt) when is_binary(prompt) do
    prompt
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(to_string(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
