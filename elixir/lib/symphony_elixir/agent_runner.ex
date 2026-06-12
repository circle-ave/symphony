defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @resource_gate_markers %{
    cloud_gate: Path.join([".symphony", "cloud-gate-blocked"]),
    local_bench_gate: Path.join([".symphony", "local-bench-gate-blocked"])
  }
  @resume_checkpoint_path Path.join([".symphony", "resume.json"])
  @comment_reply_marker "<!-- symphony-comment-reply -->"

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue_state(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        opts = maybe_load_resume_checkpoint(opts, workspace, issue)
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp maybe_load_resume_checkpoint(opts, workspace, %Issue{} = issue) when is_binary(workspace) do
    if Keyword.has_key?(opts, :resume_checkpoint) do
      opts
    else
      Keyword.put(opts, :resume_checkpoint, load_resume_checkpoint(workspace, issue))
    end
  end

  defp maybe_load_resume_checkpoint(opts, _workspace, _issue), do: opts

  defp load_resume_checkpoint(workspace, %Issue{} = issue) do
    checkpoint_path = Path.join(workspace, @resume_checkpoint_path)

    with {:ok, body} <- File.read(checkpoint_path),
         {:ok, %{} = checkpoint} <- Jason.decode(body),
         true <- resume_checkpoint_matches_issue?(checkpoint, issue) do
      Map.put(checkpoint, "path", checkpoint_path)
    else
      _ -> nil
    end
  end

  defp resume_checkpoint_matches_issue?(checkpoint, %Issue{id: issue_id, identifier: identifier}) do
    checkpoint_issue = checkpoint_value(checkpoint, "issue") || %{}
    checkpoint_issue_id = checkpoint_value(checkpoint_issue, "id")
    checkpoint_identifier = checkpoint_value(checkpoint_issue, "identifier")

    checkpoint_issue_id == issue_id or checkpoint_identifier == identifier
  end

  defp checkpoint_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(workspace, issue, issue_state_fetcher) do
        {:blocked, gate} ->
          Logger.info("Stopping agent continuation for #{issue_context(issue)} because #{gate} marker is present")

          :ok

        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    prompt = PromptBuilder.build_prompt(issue, opts)

    if Keyword.get(opts, :comment_reply, false) do
      comment_reply_prompt(issue, Keyword.get(opts, :comment_reply_marker, @comment_reply_marker)) <>
        "\n\n" <> prompt
    else
      prompt
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp comment_reply_prompt(%Issue{} = issue, marker) do
    """
    Linear comment reply mode:

    - A new actionable Linear comment was left on this issue while it is in `#{issue.state}`.
    - Reply directly to the latest comment. Do not start unrelated implementation work.
    - If the comment requests code changes, move the issue to `Rework` before changing files, then follow the normal workflow.
    - If the latest comment contains a Linear image URL, inspect it before replying. Fetch `uploads.linear.app` assets with the raw Linear token header: `Authorization: $LINEAR_API_KEY`.
    - Include this hidden marker at the end of any Linear reply you post so Symphony does not treat its own reply as a new request:
      #{marker}

    Latest comment:
    Author: #{issue.latest_comment_user_name || issue.latest_comment_user_id || "unknown"}
    Created at: #{format_comment_timestamp(issue.latest_comment_created_at)}

    #{issue.latest_comment_body || ""}
    """
  end

  defp format_comment_timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_comment_timestamp(_timestamp), do: "unknown"

  defp continue_with_issue?(workspace, %Issue{} = issue, issue_state_fetcher) do
    case resource_gate_block(workspace) do
      nil -> continue_with_issue_state(issue, issue_state_fetcher)
      gate -> {:blocked, gate}
    end
  end

  defp continue_with_issue?(_workspace, issue, _issue_state_fetcher), do: {:done, issue}

  defp continue_with_issue_state(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue_state(issue, _issue_state_fetcher), do: {:done, issue}

  defp resource_gate_block(workspace) when is_binary(workspace) do
    Enum.find_value(@resource_gate_markers, fn {gate, marker} ->
      if File.exists?(Path.join(workspace, marker)), do: gate
    end)
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
