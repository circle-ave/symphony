defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Client, Linear.ProjectScope}

  @create_comment_mutation """
  mutation SymphonyCreateComment($input: CommentCreateInput!) {
    commentCreate(input: $input) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @assign_issue_mutation """
  mutation SymphonyAssignIssue($issueId: String!, $assigneeId: String!) {
    issueUpdate(id: $issueId, input: {assigneeId: $assigneeId}) {
      success
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      project {
        slugId
      }
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @issue_scope_query """
  query SymphonyIssueProjectScope($issueId: String!) {
    issue(id: $issueId) {
      project {
        slugId
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ [])
      when is_binary(issue_id) and is_binary(body) and is_list(opts) do
    variables = %{input: comment_input(issue_id, body, opts)}

    with :ok <- ensure_issue_in_selected_project(issue_id),
         {:ok, response} <- client_module().graphql(@create_comment_mutation, variables),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec assign_issue(String.t(), String.t()) :: :ok | {:error, term()}
  def assign_issue(issue_id, assignee)
      when is_binary(issue_id) and is_binary(assignee) do
    with {:ok, assignee_id} <- resolve_assignee_id(assignee),
         :ok <- ensure_issue_in_selected_project(issue_id),
         {:ok, response} <-
           client_module().graphql(@assign_issue_mutation, %{issueId: issue_id, assigneeId: assignee_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_assign_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_assign_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp comment_input(issue_id, body, opts) do
    base_input = %{issueId: issue_id, body: body}
    tracker = Config.settings!().tracker

    if oauth_comment_identity_enabled?(tracker) do
      comment_input_with_identity(base_input, opts, tracker)
    else
      base_input
    end
  end

  defp oauth_comment_identity_enabled?(tracker), do: is_binary(tracker.oauth_access_token)

  defp comment_input_with_identity(base_input, opts, tracker) do
    configured = configured_comment_identity(tracker, Keyword.get(opts, :identity))

    create_as_user =
      first_string([
        Keyword.get(opts, :create_as_user),
        Keyword.get(opts, :comment_as),
        comment_identity_field(configured, ["create_as_user", "createAsUser", "comment_as", "name"]),
        tracker.comment_as
      ])

    display_icon_url =
      first_string([
        Keyword.get(opts, :display_icon_url),
        Keyword.get(opts, :comment_avatar_url),
        comment_identity_field(configured, ["display_icon_url", "displayIconUrl", "comment_avatar_url", "avatar_url"]),
        tracker.comment_avatar_url
      ])

    base_input
    |> maybe_put(:createAsUser, create_as_user)
    |> maybe_put(:displayIconUrl, display_icon_url)
  end

  defp configured_comment_identity(_tracker, nil), do: %{}

  defp configured_comment_identity(tracker, identity) do
    identity_config = Map.get(tracker.comment_identities, to_string(identity), %{})

    case identity_config do
      identity_config when is_map(identity_config) ->
        identity_config

      _ ->
        %{}
    end
  end

  defp comment_identity_field(config, keys) when is_map(config) do
    Enum.find_value(keys, &Map.get(config, &1))
  end

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_issue_in_selected_project(issue_id) do
    case client_module().graphql(@issue_scope_query, %{issueId: issue_id}) do
      {:ok, response} -> verify_issue_project(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         :ok <- verify_issue_project(response),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_assignee_id(assignee) when is_binary(assignee) do
    case assignee |> String.trim() do
      "" -> {:error, :missing_linear_assignee}
      "me" -> resolve_viewer_id()
      assignee_id -> {:ok, assignee_id}
    end
  end

  defp resolve_viewer_id do
    case client_module().graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => %{"id" => viewer_id}}}} when is_binary(viewer_id) ->
        case String.trim(viewer_id) do
          "" -> {:error, :missing_linear_viewer_identity}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_issue_project(%{"data" => %{"issue" => %{"project" => %{"slugId" => slug_id}}}}) do
    selected_project_slug = Config.settings!().tracker.project_slug

    if ProjectScope.matches_slug?(selected_project_slug, slug_id) do
      :ok
    else
      {:error, {:issue_outside_selected_project, slug_id, selected_project_slug}}
    end
  end

  defp verify_issue_project(_response), do: {:error, :issue_project_not_found}
end
