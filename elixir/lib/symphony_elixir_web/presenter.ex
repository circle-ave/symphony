defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  alias SymphonyElixirWeb.CodexSessionLog

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        config = Config.settings!()

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          system: system_payload(config),
          environment: environment_payload(config, snapshot),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: codex_session_logs(running)
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    last_message = summarize_message(entry.last_codex_message)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      resource_status: Map.get(entry, :resource_status),
      activity: activity_payload(:running, entry, last_message),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: last_message,
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      stream_window: stream_window_payload(entry, last_message),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      delay_type: Map.get(entry, :delay_type),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      resource_status: Map.get(entry, :resource_status),
      activity: activity_payload(:retrying, entry, nil)
    }
  end

  defp blocked_entry_payload(entry) do
    last_message = summarize_message(entry.last_codex_message)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      activity: activity_payload(:blocked, entry, last_message),
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: last_message,
      last_event_at: iso8601(entry.last_codex_timestamp),
      stream_window: stream_window_payload(entry, last_message)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      resource_status: Map.get(running, :resource_status),
      activity: activity_payload(:running, running, summarize_message(running.last_codex_message)),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      stream_window: stream_window_payload(running, summarize_message(running.last_codex_message)),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      delay_type: Map.get(retry, :delay_type),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      resource_status: Map.get(retry, :resource_status),
      activity: activity_payload(:retrying, retry, nil)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      activity: activity_payload(:blocked, blocked, summarize_message(blocked.last_codex_message)),
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp),
      stream_window: stream_window_payload(blocked, summarize_message(blocked.last_codex_message))
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp stream_window_payload(entry, fallback_message) do
    window =
      entry
      |> Map.get(:codex_stream_window, [])
      |> Enum.map(&stream_window_entry_payload/1)
      |> Enum.reject(&is_nil/1)

    case {window, fallback_message} do
      {[], message} when is_binary(message) and message != "" ->
        [
          %{
            at: iso8601(Map.get(entry, :last_codex_timestamp)),
            event: Map.get(entry, :last_codex_event),
            message: message
          }
        ]

      _ ->
        window
    end
  end

  defp stream_window_entry_payload(%{} = entry) do
    message = Map.get(entry, :message) || Map.get(entry, "message")

    if is_binary(message) and String.trim(message) != "" do
      %{
        at: iso8601(Map.get(entry, :timestamp) || Map.get(entry, "timestamp")),
        event: Map.get(entry, :event) || Map.get(entry, "event"),
        message: message
      }
    end
  end

  defp stream_window_entry_payload(_entry), do: nil

  defp system_payload(config) do
    %{
      host: hostname(),
      os: os_name(),
      schedulers_online: system_info(:schedulers_online),
      logical_processors: system_info(:logical_processors_available),
      process_count: system_info(:process_count),
      memory: memory_payload(),
      disk: disk_payload(Path.expand(config.workspace.root))
    }
  end

  defp environment_payload(config, snapshot) do
    workspace_paths = workspace_paths(snapshot)

    %{
      workspace_root: Path.expand(config.workspace.root),
      max_concurrent_agents: config.agent.max_concurrent_agents,
      available_agent_slots: max(config.agent.max_concurrent_agents - length(snapshot.running), 0),
      max_concurrent_agents_by_state: config.agent.max_concurrent_agents_by_state,
      worker_hosts: config.worker.ssh_hosts,
      worker_host_count: length(config.worker.ssh_hosts),
      polling_interval_ms: config.polling.interval_ms,
      active_workspace_count: length(workspace_paths),
      local_bench: local_bench_payload(workspace_paths)
    }
  end

  defp workspace_paths(snapshot) do
    snapshot.running
    |> Enum.concat(snapshot.retrying)
    |> Enum.concat(Map.get(snapshot, :blocked, []))
    |> Enum.map(&Map.get(&1, :workspace_path))
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp memory_payload do
    memory = :erlang.memory()

    %{
      total_bytes: Keyword.get(memory, :total),
      processes_bytes: Keyword.get(memory, :processes),
      binary_bytes: Keyword.get(memory, :binary),
      atom_bytes: Keyword.get(memory, :atom)
    }
  end

  defp disk_payload(path) when is_binary(path) do
    path = existing_path(path)

    with {output, 0} <- System.cmd("df", ["-k", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [filesystem, total_kb, used_kb, available_kb, capacity | rest] <-
           String.split(line, ~r/\s+/, trim: true),
         {total, ""} <- Integer.parse(total_kb),
         {used, ""} <- Integer.parse(used_kb),
         {available, ""} <- Integer.parse(available_kb) do
      %{
        path: path,
        filesystem: filesystem,
        mount: List.last(rest),
        capacity: capacity,
        total_bytes: total * 1024,
        used_bytes: used * 1024,
        available_bytes: available * 1024
      }
    else
      _ -> nil
    end
  end

  defp existing_path(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(expanded) ->
        expanded

      expanded == Path.dirname(expanded) ->
        expanded

      true ->
        expanded |> Path.dirname() |> existing_path()
    end
  end

  defp local_bench_payload(workspace_paths) do
    case local_bench_env(workspace_paths) do
      nil ->
        nil

      %{path: env_path, values: values} ->
        pool_size = parse_positive_int(Map.get(values, "FRAPPE_LOCAL_BENCH_POOL_SIZE"))
        base_dir = local_bench_base_dir(values)
        slots = local_bench_slots(base_dir, pool_size)

        %{
          env_path: env_path,
          mode: Map.get(values, "FRAPPE_LOCAL_BENCH_MODE"),
          pool_size: pool_size,
          warmed_slots: Enum.count(slots, & &1.exists),
          active_locks: Enum.count(slots, & &1.locked),
          base_dir: base_dir,
          setup_command: Map.get(values, "FRAPPE_LOCAL_SETUP_COMMAND"),
          slots: slots
        }
    end
  end

  defp local_bench_env(workspace_paths) do
    workspace_paths
    |> Enum.map(&Path.join([&1, ".symphony", "local-frappe-bench.env"]))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil ->
        nil

      path ->
        {:ok, contents} = File.read(path)
        %{path: path, values: parse_env(contents)}
    end
  rescue
    _ -> nil
  end

  defp parse_env(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*([A-Z0-9_]+)=(.*)\s*$/, line) do
        [_, key, value] -> Map.put(acc, key, trim_env_value(value))
        _ -> acc
      end
    end)
  end

  defp trim_env_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp local_bench_base_dir(values) do
    Map.get(values, "FRAPPE_LOCAL_BENCH_BASE_DIR") ||
      Map.get(values, "FRAPPE_LOCAL_BENCH_DIR") ||
      if String.ends_with?(
           Map.get(values, "FRAPPE_LOCAL_SETUP_COMMAND", ""),
           "with_shared_local_frappe_bench.sh"
         ) do
        Path.join(System.user_home!(), "code/ccms-shared-frappe-bench")
      end
  end

  defp local_bench_slots(base_dir, pool_size) when is_binary(base_dir) and is_integer(pool_size) do
    Enum.map(1..pool_size, fn slot ->
      path = if slot == 1, do: base_dir, else: "#{base_dir}-#{slot}"
      lock_path = "#{path}.use.lock"

      %{
        slot: slot,
        path: path,
        exists: File.dir?(path),
        locked: File.dir?(lock_path),
        lock_path: lock_path
      }
    end)
  end

  defp local_bench_slots(_base_dir, _pool_size), do: []

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_positive_int(_value), do: nil

  defp activity_payload(:running, entry, last_message) do
    case Map.get(entry, :resource_status) do
      %{} = resource_status ->
        gate = resource_status |> map_value(:gate) |> humanize_gate()

        if map_value(resource_status, :blocked) do
          %{
            status: "Waiting",
            summary: "Waiting on #{gate}",
            detail: resource_detail(resource_status),
            tone: "warning"
          }
        else
          %{
            status: "Resource check",
            summary: "#{gate} is available",
            detail: resource_detail(resource_status),
            tone: "ok"
          }
        end

      _ ->
        %{
          status: activity_status(entry.last_codex_event, last_message),
          summary: last_message || "Starting agent",
          detail: activity_detail(entry),
          tone: "active"
        }
    end
  end

  defp activity_payload(:retrying, entry, _last_message) do
    case Map.get(entry, :resource_status) do
      %{} = resource_status ->
        gate = resource_status |> map_value(:gate) |> humanize_gate()

        if map_value(resource_status, :blocked) do
          %{
            status: "Parked",
            summary: "Waiting on #{gate}",
            detail: entry.error || resource_detail(resource_status),
            tone: "warning"
          }
        else
          %{
            status: "Retry ready",
            summary: "#{gate} released; waiting for a slot",
            detail: entry.error,
            tone: "ok"
          }
        end

      _ ->
        %{
          status: "Backoff",
          summary: entry.error || "Waiting for retry window",
          detail: retry_detail(entry),
          tone: "warning"
        }
    end
  end

  defp activity_payload(:blocked, entry, last_message) do
    %{
      status: "Blocked",
      summary: entry.error || last_message || "Waiting for operator input",
      detail: last_message,
      tone: "danger"
    }
  end

  defp activity_status(event, message) do
    text = "#{event || ""} #{message || ""}" |> String.downcase()

    [
      {"command", "Running command"},
      {"tool", "Using tool"},
      {"plan", "Planning"},
      {"reasoning", "Reasoning"},
      {"agent message", "Writing"},
      {"session", "Starting"}
    ]
    |> Enum.find_value("Working", fn {needle, label} ->
      if String.contains?(text, needle), do: label
    end)
  end

  defp activity_detail(entry) do
    [to_string(entry.last_codex_event || "n/a"), iso8601(entry.last_codex_timestamp)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp retry_detail(entry) do
    delay_type = Map.get(entry, :delay_type)

    ["attempt #{entry.attempt}", delay_type && "delay #{delay_type}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp resource_detail(resource_status) do
    [map_value(resource_status, :marker_path), map_value(resource_status, :lock_path)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp humanize_gate("cloud_gate"), do: "Frappe Cloud gate"
  defp humanize_gate("local_bench_gate"), do: "local bench gate"
  defp humanize_gate(gate) when is_binary(gate), do: String.replace(gate, "_", " ")
  defp humanize_gate(_gate), do: "resource gate"

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp system_info(key) do
    :erlang.system_info(key)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  rescue
    _ -> "unknown"
  end

  defp os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, name} -> "Unix/#{name}"
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp codex_session_logs(nil), do: []
  defp codex_session_logs(running), do: CodexSessionLog.payloads_for_session(running.session_id)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
