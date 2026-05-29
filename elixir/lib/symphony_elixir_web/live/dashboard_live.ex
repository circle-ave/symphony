defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Codex.Controls
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:controls, load_controls())
      |> assign(:control_notice, nil)
      |> assign(:control_error, nil)
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_issue_identifier, nil)
      |> assign(:selected_issue_payload, nil)
      |> assign(:selected_issue_error, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:controls, load_controls())
     |> assign(:now, DateTime.utc_now())
     |> refresh_selected_issue()}
  end

  @impl true
  def handle_event("update-controls", %{"controls" => controls}, socket) do
    case Controls.update(controls) do
      {:ok, payload} ->
        :ok = ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:controls, payload)
         |> assign(:payload, load_payload())
         |> assign(:control_notice, "Saved")
         |> assign(:control_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:control_notice, nil)
         |> assign(:control_error, Controls.error_message(reason))}
    end
  end

  @impl true
  def handle_event("freeze-orchestrator", _params, socket) do
    case Orchestrator.freeze(orchestrator(), reason: "dashboard restart freeze") do
      :unavailable ->
        {:noreply,
         socket
         |> assign(:control_notice, nil)
         |> assign(:control_error, "Orchestrator is unavailable")}

      _payload ->
        :ok = ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign(:control_notice, "Frozen")
         |> assign(:control_error, nil)}
    end
  end

  @impl true
  def handle_event("resume-orchestrator", _params, socket) do
    case Orchestrator.resume(orchestrator()) do
      :unavailable ->
        {:noreply,
         socket
         |> assign(:control_notice, nil)
         |> assign(:control_error, "Orchestrator is unavailable")}

      _payload ->
        :ok = ObservabilityPubSub.broadcast_update()

        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign(:control_notice, "Resuming")
         |> assign(:control_error, nil)}
    end
  end

  @impl true
  def handle_event("inspect-session", %{"issue" => issue_identifier}, socket) do
    {:noreply, inspect_issue(socket, issue_identifier)}
  end

  @impl true
  def handle_event("clear-session-inspector", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue_identifier, nil)
     |> assign(:selected_issue_payload, nil)
     |> assign(:selected_issue_error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <aside class="dashboard-sidebar" aria-label="Dashboard navigation">
        <div class="sidebar-brand">
          <span class="brand-mark">S</span>
          <div>
            <p class="eyebrow">Symphony</p>
            <strong>Ops Dash</strong>
          </div>
        </div>

        <nav class="sidebar-nav" aria-label="Dashboard sections">
          <a class="sidebar-nav-item sidebar-nav-item-active" href="#overview">
            <span>Overview</span>
            <b class="numeric"><%= total_active_count(@payload) %></b>
          </a>
          <a class="sidebar-nav-item" href="#agents">
            <span>Agents</span>
            <b class="numeric"><%= payload_count(@payload, :running) %></b>
          </a>
          <a class="sidebar-nav-item" href="#operator-roles">
            <span>Roles</span>
            <b class="numeric"><%= length(agent_roles(@payload)) %></b>
          </a>
          <a class="sidebar-nav-item" href="#queue">
            <span>Queue</span>
            <b class="numeric"><%= queue_count(@payload) %></b>
          </a>
          <a class="sidebar-nav-item" href="#controls">
            <span>Controls</span>
            <b>Ops</b>
          </a>
        </nav>

        <div class="sidebar-panel">
          <span class="metric-label">Runtime</span>
          <strong class="numeric"><%= sidebar_runtime(@payload, @now) %></strong>
          <small><%= sidebar_host(@payload) %></small>
        </div>
      </aside>

      <div class="dashboard-main">
        <header class="topbar hero-card">
          <div class="hero-grid">
            <div>
              <p class="eyebrow">
                Symphony Observability
              </p>
              <h1 class="hero-title">
                Operations Dashboard
              </h1>
              <p class="hero-copy">
                Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
              </p>
            </div>

            <div class="status-stack">
              <button
                type="button"
                class="theme-toggle"
                data-theme-toggle
                aria-label="Toggle day and night theme"
              >
                <span data-theme-toggle-label>Theme</span>
              </button>
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Offline
              </span>
              <%= if frozen?(@payload) do %>
                <span class="status-badge status-badge-frozen">
                  <span class="status-badge-dot"></span>
                  Frozen
                </span>
              <% end %>
            </div>
          </div>
        </header>

        <main class="dashboard-content">
          <section class="section-card controls-card" id="controls">
            <div class="section-header">
              <div>
                <h2 class="section-title">Agent controls</h2>
                <p class="section-copy">Model and reasoning effort for new Codex agent sessions.</p>
              </div>
              <%= if @control_notice do %>
                <span class="control-status control-status-ok"><%= @control_notice %></span>
              <% end %>
            </div>

            <%= if control_error?(@controls) do %>
              <p class="empty-state"><%= @controls.error.message %></p>
            <% else %>
              <form class="control-form" phx-submit="update-controls">
                <label class="control-field">
                  <span>Model</span>
                  <input
                    type="text"
                    name="controls[model]"
                    value={@controls.model || ""}
                    placeholder="default"
                  />
                </label>

                <label class="control-field">
                  <span>Reasoning effort</span>
                  <select
                    id={"agent-reasoning-effort-#{@controls.reasoning_effort || "default"}"}
                    name="controls[reasoning_effort]"
                  >
                    <%= Phoenix.HTML.Form.options_for_select(
                      reasoning_effort_options(@controls),
                      @controls.reasoning_effort || ""
                    ) %>
                  </select>
                </label>

                <button type="submit">Apply</button>
              </form>

              <%= if @control_error do %>
                <p class="control-status control-status-error"><%= @control_error %></p>
              <% end %>

              <pre class="code-panel command-panel"><%= @controls.command %></pre>

              <div class="restart-controls">
                <div>
                  <span class="metric-label">Restart state</span>
                  <strong><%= if frozen?(@payload), do: "Frozen", else: "Dispatching" %></strong>
                  <%= if frozen?(@payload) && @payload.freeze[:reason] do %>
                    <small><%= @payload.freeze.reason %></small>
                  <% end %>
                </div>

                <%= if frozen?(@payload) do %>
                  <button type="button" class="secondary" phx-click="resume-orchestrator">
                    Resume
                  </button>
                <% else %>
                  <button type="button" class="secondary" phx-click="freeze-orchestrator">
                    Freeze
                  </button>
                <% end %>
              </div>
            <% end %>
          </section>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="ops-summary-grid" id="overview">
          <article class="section-card chart-card">
            <div class="mini-header">
              <div>
                <h2 class="section-title">Workload</h2>
                <p class="section-copy">Active, retrying, and blocked issues.</p>
              </div>
              <span class="metric-pill numeric"><%= total_active(@payload) %> total</span>
            </div>

            <div class="workload-chart">
              <div class="donut-chart" style={workload_ring_style(@payload)} aria-hidden="true">
                <span class="numeric"><%= @payload.counts.running %></span>
              </div>
              <div class="legend-stack">
                <span><i class="legend-dot legend-running"></i>Running <b class="numeric"><%= @payload.counts.running %></b></span>
                <span><i class="legend-dot legend-retrying"></i>Retrying <b class="numeric"><%= @payload.counts.retrying %></b></span>
                <span><i class="legend-dot legend-blocked"></i>Blocked <b class="numeric"><%= @payload.counts.blocked %></b></span>
              </div>
            </div>
          </article>

          <article class="section-card chart-card">
            <div class="mini-header">
              <div>
                <h2 class="section-title">Capacity</h2>
                <p class="section-copy"><%= @payload.system.host %> · <%= @payload.system.os %></p>
              </div>
              <span class="metric-pill numeric"><%= @payload.environment.available_agent_slots %> slots open</span>
            </div>

            <div class="bar-stack">
              <div class="bar-row">
                <span>Agent slots</span>
                <strong class="numeric"><%= @payload.counts.running %>/<%= @payload.environment.max_concurrent_agents %></strong>
                <div class="meter"><span style={bar_style(percent(@payload.counts.running, @payload.environment.max_concurrent_agents))}></span></div>
              </div>
              <div class="bar-row">
                <span>Disk used</span>
                <strong><%= format_disk_compact(@payload.system.disk) %></strong>
                <div class="meter meter-warning"><span style={bar_style(disk_used_percent(@payload.system.disk))}></span></div>
              </div>
              <div class="bar-row">
                <span>Bench warmed</span>
                <strong><%= format_local_bench_compact(@payload.environment.local_bench) %></strong>
                <div class="meter"><span style={bar_style(local_bench_percent(@payload.environment.local_bench))}></span></div>
              </div>
            </div>
          </article>

          <article class="section-card chart-card">
            <div class="mini-header">
              <div>
                <h2 class="section-title">Throughput</h2>
                <p class="section-copy">Runtime, tokens, and upstream pressure.</p>
              </div>
              <span class="metric-pill numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            </div>

            <div class="token-chart">
              <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
              <div class="split-bar">
                <span class="split-input" style={bar_style(token_percent(@payload.codex_totals.input_tokens, @payload.codex_totals))}></span>
                <span class="split-output" style={bar_style(token_percent(@payload.codex_totals.output_tokens, @payload.codex_totals))}></span>
              </div>
              <div class="legend-stack legend-inline">
                <span><i class="legend-dot legend-running"></i>In <b class="numeric"><%= format_int(@payload.codex_totals.input_tokens) %></b></span>
                <span><i class="legend-dot legend-output"></i>Out <b class="numeric"><%= format_int(@payload.codex_totals.output_tokens) %></b></span>
              </div>
              <p class="rate-limit-line"><%= rate_limit_summary(@payload.rate_limits) %></p>
            </div>
          </article>
         </section>

         <section class="section-card role-section" id="operator-roles">
           <div class="mini-header">
             <div>
               <h2 class="section-title">Operator roles</h2>
               <p class="section-copy">Scheduled non-ticket roles, last result, and next due time.</p>
             </div>
             <span class="metric-pill numeric"><%= length(agent_roles(@payload)) %></span>
           </div>

           <%= if agent_roles(@payload) == [] do %>
             <p class="empty-state">No operator roles configured.</p>
           <% else %>
             <div class="role-grid">
               <article :for={role <- agent_roles(@payload)} class="role-card">
                 <div class="role-card-head">
                   <div>
                     <span class="issue-id"><%= role.name %></span>
                     <span class="muted"><%= role.run %></span>
                   </div>
                   <span class={role_status_class(role.status)}>
                     <%= role.status %>
                   </span>
                 </div>

                 <div class="agent-meta-grid">
                   <span>
                     <small>Next</small>
                     <b class="numeric"><%= format_millis(role.next_due_in_ms) %></b>
                   </span>
                   <span>
                     <small>Last</small>
                     <b class="numeric"><%= format_millis(role.last_duration_ms) %></b>
                   </span>
                   <span>
                     <small>Exit</small>
                     <b class="numeric"><%= role.last_exit_status || "n/a" %></b>
                   </span>
                 </div>

                 <p class="activity-summary"><%= role_detail(role) %></p>
                 <p class="role-path mono"><%= role.cwd %></p>
               </article>
             </div>
           <% end %>
         </section>

         <section class="section-card agent-section" id="agents">
          <div class="mini-header">
            <div>
              <h2 class="section-title">Agents</h2>
              <p class="section-copy">Current activity, stream tail, runtime, and token load.</p>
            </div>
            <span class="metric-pill numeric"><%= @payload.counts.running %>/<%= @payload.environment.max_concurrent_agents %></span>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="agent-grid">
              <article
                :for={entry <- @payload.running}
                class={["agent-card", @selected_issue_identifier == entry.issue_identifier && "is-selected"]}
              >
                <div class="agent-card-head">
                  <div>
                    <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    <span class={state_badge_class(entry.state)}>
                      <%= entry.state %>
                    </span>
                  </div>
                  <span class={activity_badge_class(entry.activity.tone)}>
                    <%= entry.activity.status %>
                  </span>
                </div>

                <p class="activity-summary"><%= entry.activity.summary %></p>

                <div class="agent-meta-grid">
                  <span>
                    <small>Runtime</small>
                    <b class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></b>
                  </span>
                  <span>
                    <small>Tokens</small>
                    <b class="numeric"><%= format_int(entry.tokens.total_tokens) %></b>
                  </span>
                  <span>
                    <small>Workspace</small>
                    <b class="mono"><%= workspace_basename(entry.workspace_path) %></b>
                  </span>
                </div>

                <%= if entry.stream_window != [] do %>
                  <div class="stream-window">
                    <span class="stream-window-label">Recent stream</span>
                    <ol>
                      <li :for={item <- entry.stream_window}>
                        <span class="stream-message"><%= item.message %></span>
                        <%= if item.at do %>
                          <span class="stream-time mono numeric"><%= item.at %></span>
                        <% end %>
                      </li>
                    </ol>
                  </div>
                <% end %>

                <div class="agent-actions">
                  <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                  <button
                    type="button"
                    class={[
                      "subtle-button issue-inspect-button",
                      @selected_issue_identifier == entry.issue_identifier &&
                        "subtle-button-active"
                    ]}
                    phx-click="inspect-session"
                    phx-value-issue={entry.issue_identifier}
                  >
                    Inspect thread
                  </button>
                  <%= if entry.session_id do %>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy ID"
                      data-copy={entry.session_id}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy ID
                    </button>
                  <% end %>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <%= if @selected_issue_identifier do %>
          <section class="section-card inspector-card" id="agent-thread">
            <div class="section-header">
              <div>
                <h2 class="section-title">Agent thread</h2>
                <p class="section-copy">
                  <%= @selected_issue_identifier %>
                  <%= if @selected_issue_payload && @selected_issue_payload.running do %>
                    · session <span class="mono numeric"><%= @selected_issue_payload.running.session_id %></span>
                  <% end %>
                </p>
              </div>

              <button
                type="button"
                class="subtle-button"
                phx-click="clear-session-inspector"
              >
                Close
              </button>
            </div>

            <%= if @selected_issue_error do %>
              <p class="empty-state"><%= @selected_issue_error %></p>
            <% else %>
              <div class="inspector-grid">
                <div class="inspector-meta">
                  <span class="metric-label">Status</span>
                  <span><%= @selected_issue_payload.status %></span>
                </div>
                <div class="inspector-meta">
                  <span class="metric-label">Workspace</span>
                  <span class="mono"><%= @selected_issue_payload.workspace.path %></span>
                </div>
                <div class="inspector-meta">
                  <span class="metric-label">Last event</span>
                  <span>
                    <%= if @selected_issue_payload.running do %>
                      <%= @selected_issue_payload.running.last_message || @selected_issue_payload.running.last_event || "n/a" %>
                    <% else %>
                      n/a
                    <% end %>
                  </span>
                </div>
              </div>

              <%= if @selected_issue_payload.logs.codex_session_logs == [] do %>
                <p class="empty-state">
                  No local Codex session log found for this session.
                </p>
              <% else %>
                <div
                  :for={log <- @selected_issue_payload.logs.codex_session_logs}
                  class="thread-log"
                >
                  <div class="thread-log-meta">
                    <span class="mono"><%= log.path %></span>
                    <span>
                      <%= format_int(log.size_bytes) %> bytes
                      <%= if log.modified_at do %>
                        · <span class="mono numeric"><%= log.modified_at %></span>
                      <% end %>
                    </span>
                  </div>

                  <%= if log.truncated do %>
                    <p class="thread-note">Showing latest <%= length(log.entries) %> events.</p>
                  <% end %>

                  <ol class="thread-list">
                    <li :for={event <- log.entries} class="thread-event">
                      <div class="thread-event-meta">
                        <span class="mono numeric"><%= event.at || "n/a" %></span>
                        <span><%= event.kind %></span>
                      </div>
                      <pre><%= event.summary %></pre>
                    </li>
                  </ol>
                </div>
              <% end %>
            <% end %>
          </section>
        <% end %>

        <section class="queue-grid" id="queue">
          <article class="section-card queue-card">
            <div class="mini-header">
              <div>
                <h2 class="section-title">Retry queue</h2>
                <p class="section-copy">Backoff, slot pressure, and resource-gate waits.</p>
              </div>
              <span class="metric-pill numeric"><%= @payload.counts.retrying %></span>
            </div>

            <%= if @payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="queue-list">
                <div :for={entry <- @payload.retrying} class="queue-row">
                  <div>
                    <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    <span class="muted">attempt <%= entry.attempt %></span>
                  </div>
                  <p><%= entry.error || "n/a" %></p>
                  <div class="queue-meta">
                    <span class="mono numeric"><%= entry.due_at || "n/a" %></span>
                    <span><%= entry.delay_type || "retry" %></span>
                    <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                  </div>
                </div>
              </div>
            <% end %>
          </article>

          <article class="section-card queue-card">
            <div class="mini-header">
              <div>
                <h2 class="section-title">Blocked</h2>
                <p class="section-copy">Operator input, approvals, and hard blockers.</p>
              </div>
              <span class="metric-pill numeric"><%= @payload.counts.blocked %></span>
            </div>

            <%= if @payload.blocked == [] do %>
              <p class="empty-state">No blocked sessions.</p>
            <% else %>
              <div class="queue-list">
                <div :for={entry <- @payload.blocked} class="queue-row">
                  <div>
                    <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    <span class={state_badge_class(entry.state || "Blocked")}>
                      <%= entry.state || "Blocked" %>
                    </span>
                  </div>
                  <p><%= entry.last_message || entry.error || "n/a" %></p>
                  <div class="queue-meta">
                    <span class="mono numeric"><%= entry.blocked_at || "n/a" %></span>
                    <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                  </div>
                </div>
              </div>
            <% end %>
          </article>
        </section>
      <% end %>
        </main>
      </div>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_controls do
    case Controls.current() do
      {:ok, payload} -> payload
      {:error, reason} -> %{error: %{message: Controls.error_message(reason)}}
    end
  end

  defp control_error?(%{error: _error}), do: true
  defp control_error?(_controls), do: false

  defp refresh_selected_issue(%{assigns: %{selected_issue_identifier: nil}} = socket), do: socket

  defp refresh_selected_issue(%{assigns: %{selected_issue_identifier: issue_identifier}} = socket) do
    inspect_issue(socket, issue_identifier)
  end

  defp inspect_issue(socket, issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        socket
        |> assign(:selected_issue_identifier, issue_identifier)
        |> assign(:selected_issue_payload, payload)
        |> assign(:selected_issue_error, nil)

      {:error, :issue_not_found} ->
        socket
        |> assign(:selected_issue_identifier, issue_identifier)
        |> assign(:selected_issue_payload, nil)
        |> assign(:selected_issue_error, "Issue is no longer active in the current snapshot.")
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp total_active(payload) do
    payload.counts.running + payload.counts.retrying + payload.counts.blocked
  end

  defp total_active_count(payload) do
    payload_count(payload, :running) + payload_count(payload, :retrying) + payload_count(payload, :blocked)
  end

  defp queue_count(payload), do: payload_count(payload, :retrying) + payload_count(payload, :blocked)

  defp payload_count(%{counts: counts}, key) when is_map(counts), do: Map.get(counts, key, 0) || 0
  defp payload_count(_payload, _key), do: 0

  defp sidebar_runtime(%{codex_totals: _totals, running: running} = payload, now) when is_list(running) do
    format_runtime_seconds(total_runtime_seconds(payload, now))
  end

  defp sidebar_runtime(_payload, _now), do: "n/a"

  defp sidebar_host(%{system: %{host: host}}) when is_binary(host), do: host
  defp sidebar_host(_payload), do: "snapshot offline"

  defp frozen?(%{freeze: %{active: true}}), do: true
  defp frozen?(_payload), do: false

  defp agent_roles(%{agent_roles: roles}) when is_list(roles), do: roles
  defp agent_roles(_payload), do: []

  defp role_status_class(status) do
    normalized =
      status
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
      |> String.downcase()

    ["role-status", "role-status-#{normalized}"]
  end

  defp role_detail(role) do
    role.last_error || role.last_output || role.command || "No result yet."
  end

  defp format_millis(nil), do: "n/a"

  defp format_millis(ms) when is_integer(ms) do
    seconds = div(max(ms, 0) + 999, 1_000)
    "#{seconds}s"
  end

  defp format_millis(_ms), do: "n/a"

  defp workload_ring_style(payload) do
    total = total_active(payload)

    if total == 0 do
      "background: conic-gradient(var(--line) 0 100%);"
    else
      running = percent(payload.counts.running, total)
      retrying = running + percent(payload.counts.retrying, total)

      "background: conic-gradient(var(--accent) 0 #{running}%, #d99a1b #{running}% #{retrying}%, var(--danger) #{retrying}% 100%);"
    end
  end

  defp bar_style(percent), do: "width: #{clamp_percent(percent)}%;"

  defp percent(value, total) when is_number(value) and is_number(total) and total > 0 do
    value
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round(1)
    |> clamp_percent()
  end

  defp percent(_value, _total), do: 0

  defp clamp_percent(value) when is_number(value) do
    value
    |> max(0)
    |> min(100)
  end

  defp disk_used_percent(%{used_bytes: used, total_bytes: total}), do: percent(used, total)
  defp disk_used_percent(_disk), do: 0

  defp local_bench_percent(%{warmed_slots: warmed, pool_size: pool_size}), do: percent(warmed, pool_size)
  defp local_bench_percent(_local_bench), do: 0

  defp token_percent(value, %{total_tokens: total}), do: percent(value, total)
  defp token_percent(_value, _totals), do: 0

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_bytes(bytes) when is_integer(bytes) do
    units = [{"TiB", 1_099_511_627_776}, {"GiB", 1_073_741_824}, {"MiB", 1_048_576}, {"KiB", 1024}]

    case Enum.find(units, fn {_unit, size} -> bytes >= size end) do
      {unit, size} ->
        value = bytes / size
        "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"

      nil ->
        "#{bytes} B"
    end
  end

  defp format_bytes(_bytes), do: "n/a"

  defp format_disk_compact(nil), do: "n/a"
  defp format_disk_compact(disk), do: "#{disk.capacity} used · #{format_bytes(disk.available_bytes)} free"

  defp format_local_bench_compact(nil), do: "n/a"

  defp format_local_bench_compact(%{pool_size: pool_size, warmed_slots: warmed_slots})
       when is_integer(pool_size) do
    "#{warmed_slots}/#{pool_size}"
  end

  defp format_local_bench_compact(_local_bench), do: "configured"

  defp activity_badge_class(tone) do
    base = "activity-badge"

    case tone do
      "ok" -> "#{base} activity-badge-ok"
      "warning" -> "#{base} activity-badge-warning"
      "danger" -> "#{base} activity-badge-danger"
      _ -> "#{base} activity-badge-active"
    end
  end

  defp workspace_basename(path) when is_binary(path), do: Path.basename(path)
  defp workspace_basename(_path), do: "n/a"

  defp rate_limit_summary(nil), do: "Rate limits: n/a"

  defp rate_limit_summary(rate_limits) when is_map(rate_limits) do
    ["primary", "secondary"]
    |> Enum.map(fn bucket -> rate_limit_bucket_summary(bucket, map_value(rate_limits, bucket)) end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Rate limits: #{inspect(rate_limits, limit: 4)}"
      parts -> "Rate limits: #{Enum.join(parts, " · ")}"
    end
  end

  defp rate_limit_summary(_rate_limits), do: "Rate limits: n/a"

  defp rate_limit_bucket_summary(label, %{} = bucket) do
    used = map_value(bucket, "usedPercent")
    window = map_value(bucket, "windowDurationMins")

    cond do
      is_number(used) and is_integer(window) -> "#{label} #{used}%/#{window}m"
      is_number(used) -> "#{label} #{used}%"
      true -> nil
    end
  end

  defp rate_limit_bucket_summary(_label, _bucket), do: nil

  defp map_value(map, "primary"), do: Map.get(map, "primary") || Map.get(map, :primary)
  defp map_value(map, "secondary"), do: Map.get(map, "secondary") || Map.get(map, :secondary)
  defp map_value(map, "usedPercent"), do: Map.get(map, "usedPercent") || Map.get(map, :usedPercent)
  defp map_value(map, "windowDurationMins"), do: Map.get(map, "windowDurationMins") || Map.get(map, :windowDurationMins)
  defp map_value(map, key), do: Map.get(map, key)

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp effort_label("low"), do: "Low / fastest"
  defp effort_label("medium"), do: "Medium"
  defp effort_label("high"), do: "High"
  defp effort_label("xhigh"), do: "XHigh / deepest"
  defp effort_label(effort), do: effort

  defp reasoning_effort_options(controls) do
    [{"Default", ""} | Enum.map(controls.reasoning_effort_options, &{effort_label(&1), &1})]
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
