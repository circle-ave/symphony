defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Codex.Controls
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter, StaticAssets}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec controls(Conn.t(), map()) :: Conn.t()
  def controls(conn, _params) do
    case Controls.current() do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        control_error_response(conn, reason)
    end
  end

  @spec update_controls(Conn.t(), map()) :: Conn.t()
  def update_controls(conn, params) do
    case Controls.update(params) do
      {:ok, payload} ->
        :ok = ObservabilityPubSub.broadcast_update()
        json(conn, payload)

      {:error, reason} ->
        control_error_response(conn, reason)
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec freeze(Conn.t(), map()) :: Conn.t()
  def freeze(conn, params) do
    case Presenter.freeze_request_payload(orchestrator(), Map.get(params, "reason")) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params) do
    case Presenter.resume_request_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec reload_version(Conn.t(), map()) :: Conn.t()
  def reload_version(conn, _params) do
    json(conn, StaticAssets.reload_version_payload())
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp control_error_response(conn, {:invalid_controls, _message} = reason) do
    error_response(conn, 400, "invalid_controls", Controls.error_message(reason))
  end

  defp control_error_response(conn, {:unsupported_workflow_format, _message} = reason) do
    error_response(conn, 422, "unsupported_workflow_format", Controls.error_message(reason))
  end

  defp control_error_response(conn, reason) do
    error_response(conn, 500, "controls_unavailable", Controls.error_message(reason))
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
