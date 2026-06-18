defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Linear.ProjectScope, ReviewRecipe, Tracker}
  alias SymphonyElixir.Jira.Client, as: JiraClient

  @linear_graphql_tool "linear_graphql"
  @jira_issue_attachments_tool "jira_issue_attachments"
  @linear_comment_reply_tool "linear_comment_reply"
  @comment_reply_marker "<!-- symphony-comment-reply -->"
  @linear_graphql_description """
  Execute a Linear GraphQL query or mutation using Symphony's configured auth. Prefer injected issue/workpad fields first. Use linear_comment_reply for agent replies so the configured comment identity is applied.
  """
  @linear_comment_reply_description """
  Atomically save a revised active Codex Workpad and post the reply for the latest Linear comment.
  """
  @jira_issue_attachments_description """
  Fetch Jira issue attachment metadata and download matching attachments into the current workspace using Symphony's configured Jira auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @jira_issue_attachments_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue"],
    "properties" => %{
      "issue" => %{
        "type" => "string",
        "description" => "Jira issue key or browse URL, for example TP-24 or https://example.atlassian.net/browse/TP-24."
      },
      "filename_contains" => %{
        "type" => ["string", "null"],
        "description" => "Optional case-insensitive filename filter."
      },
      "download" => %{
        "type" => "boolean",
        "description" => "Whether to download matching attachments into .symphony/jira-attachments. Defaults to true."
      }
    }
  }
  @linear_comment_reply_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["workpad_body", "reply_body"],
    "properties" => %{
      "workpad_body" => %{
        "type" => "string",
        "description" => "The complete replacement body for the active ## Codex Workpad comment."
      },
      "reply_body" => %{
        "type" => "string",
        "description" => "The concise reply to post to the latest human comment. The Symphony marker is appended automatically when absent."
      },
      "state_name" => %{
        "type" => ["string", "null"],
        "description" => "Optional issue state to move to only when the comment reply concludes the issue must be parked or reworked, for example Waiting or Rework."
      }
    }
  }
  @comment_update_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
    }
  }
  """
  @review_state_names MapSet.new(["human review", "in review", "review"])
  @review_ready_file Path.join([".symphony", "review-ready.json"])
  @acceptance_agent_review_file Path.join([".symphony", "acceptance-agent-review.json"])
  @acceptance_agent_review_schema "symphony.acceptance-agent-review.v1"
  @review_blocker_files [
    Path.join([".symphony", "cloud-gate-blocked"]),
    Path.join([".symphony", "local-bench-gate-blocked"])
  ]
  @review_state_guard_query """
  query SymphonyReviewStateGuard($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      team {
        states {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """
  @linear_scope_issue_query """
  query SymphonyLinearScopeIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      project {
        id
        slugId
      }
    }
  }
  """
  @linear_scope_comment_query """
  query SymphonyLinearScopeComment($commentId: String!) {
    comment(id: $commentId) {
      id
      issue {
        id
        identifier
        project {
          id
          slugId
        }
      }
    }
  }
  """
  @linear_scope_project_query """
  query SymphonyLinearScopeProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        slugId
      }
    }
  }
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_comment_reply_tool ->
        execute_linear_comment_reply(arguments, opts)

      @jira_issue_attachments_tool ->
        execute_jira_issue_attachments(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @jira_issue_attachments_tool,
        "description" => @jira_issue_attachments_description,
        "inputSchema" => @jira_issue_attachments_input_schema
      }
    ]
  end

  @spec comment_reply_tool_specs() :: [map()]
  def comment_reply_tool_specs do
    [
      %{
        "name" => @linear_comment_reply_tool,
        "description" => @linear_comment_reply_description,
        "inputSchema" => @linear_comment_reply_input_schema
      },
      %{
        "name" => @jira_issue_attachments_tool,
        "description" => @jira_issue_attachments_description,
        "inputSchema" => @jira_issue_attachments_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- authorize_linear_graphql(query, variables, opts, linear_client),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_jira_issue_attachments(arguments, opts) do
    jira_client = Keyword.get(opts, :jira_client, &JiraClient.issue_attachments/2)

    with {:ok, params} <- normalize_jira_issue_attachments_arguments(arguments),
         {:ok, response} <- jira_client.(params, opts) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(jira_tool_error_payload(reason))
    end
  end

  defp execute_linear_comment_reply(arguments, opts) do
    with {:ok, issue} <- comment_reply_issue(opts),
         {:ok, params} <- normalize_linear_comment_reply_arguments(arguments),
         :ok <- save_comment_reply_workpad(issue, params, opts),
         :ok <- maybe_move_comment_reply_issue(issue, params),
         :ok <- create_comment_reply(issue, params) do
      dynamic_tool_response(true, encode_payload(%{"saved" => true, "issueId" => issue.id}))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp comment_reply_issue(opts) do
    case Keyword.get(opts, :issue) do
      %{id: issue_id} = issue when is_binary(issue_id) and issue_id != "" -> {:ok, issue}
      _ -> {:error, :missing_comment_reply_issue}
    end
  end

  defp normalize_linear_comment_reply_arguments(arguments) when is_map(arguments) do
    with {:ok, workpad_body} <- required_string_argument(arguments, "workpad_body"),
         {:ok, reply_body} <- required_string_argument(arguments, "reply_body"),
         {:ok, state_name} <- optional_string_argument(arguments, "state_name") do
      {:ok, %{workpad_body: workpad_body, reply_body: reply_body, state_name: state_name}}
    end
  end

  defp normalize_linear_comment_reply_arguments(_arguments), do: {:error, :invalid_comment_reply_arguments}

  defp required_string_argument(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    case value do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing_comment_reply_argument, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing_comment_reply_argument, key}}
    end
  end

  defp optional_string_argument(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    case value do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, {:invalid_comment_reply_argument, key}}
    end
  end

  defp save_comment_reply_workpad(issue, %{workpad_body: workpad_body}, opts) do
    cond do
      !String.starts_with?(String.trim_leading(workpad_body), "## Codex Workpad") ->
        {:error, :invalid_comment_reply_workpad}

      is_binary(Map.get(issue, :active_workpad_comment_id)) ->
        update_comment_reply_workpad(issue.active_workpad_comment_id, workpad_body, opts)

      true ->
        Tracker.create_comment(issue.id, workpad_body, identity: :workpad)
    end
  end

  defp update_comment_reply_workpad(comment_id, body, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case linear_client.(@comment_update_mutation, %{commentId: comment_id, body: body}, []) do
      {:ok, response} ->
        if get_in(response, ["data", "commentUpdate", "success"]) == true do
          :ok
        else
          {:error, :comment_update_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_move_comment_reply_issue(_issue, %{state_name: state_name}) when state_name in [nil, ""], do: :ok

  defp maybe_move_comment_reply_issue(issue, %{state_name: state_name}) do
    Tracker.update_issue_state(issue.id, state_name)
  end

  defp create_comment_reply(issue, %{reply_body: reply_body}) do
    Tracker.create_comment(issue.id, ensure_comment_reply_marker(reply_body), identity: :comment_reply)
  end

  defp ensure_comment_reply_marker(reply_body) do
    if String.contains?(reply_body, @comment_reply_marker) do
      reply_body
    else
      String.trim_trailing(reply_body) <> "\n\n" <> @comment_reply_marker
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_jira_issue_attachments_arguments(arguments) when is_binary(arguments) do
    normalize_jira_issue_attachments_arguments(%{"issue" => arguments})
  end

  defp normalize_jira_issue_attachments_arguments(arguments) when is_map(arguments) do
    with {:ok, issue} <- normalize_jira_issue(arguments),
         {:ok, filename_contains} <- normalize_optional_jira_string(arguments, "filename_contains"),
         {:ok, download} <- normalize_optional_jira_boolean(arguments, "download", true) do
      params =
        %{
          "issue" => issue,
          "filename_contains" => filename_contains,
          "download" => download
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, params}
    end
  end

  defp normalize_jira_issue_attachments_arguments(_arguments), do: {:error, :invalid_jira_arguments}

  defp normalize_jira_issue(arguments) do
    issue = Map.get(arguments, "issue") || Map.get(arguments, :issue)

    case issue do
      issue when is_binary(issue) ->
        case String.trim(issue) do
          "" -> {:error, :missing_jira_issue}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_jira_issue}
    end
  end

  defp normalize_optional_jira_string(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    case value do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.trim(value)}
      _ -> {:error, {:invalid_jira_argument, key}}
    end
  end

  defp normalize_optional_jira_boolean(arguments, key, default) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    case value do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_jira_argument, key}}
    end
  end

  defp authorize_linear_graphql(query, variables, opts, linear_client) do
    with :ok <- authorize_linear_mutation_scope(query, variables, linear_client) do
      if review_guard_required?(opts) and issue_state_update_query?(query) do
        authorize_issue_state_update(query, variables, opts, linear_client)
      else
        :ok
      end
    end
  end

  defp authorize_linear_mutation_scope(query, variables, linear_client) do
    if graphql_mutation?(query) do
      query
      |> linear_mutation_targets(variables)
      |> authorize_linear_mutation_targets(linear_client)
    else
      :ok
    end
  end

  defp graphql_mutation?(query) when is_binary(query) do
    String.match?(query, ~r/\A\s*mutation\b/)
  end

  defp linear_mutation_targets(query, variables) do
    [
      issue_mutation_target(query, variables, "issueUpdate", [["issueId"], ["issue_id"], ["id"], ["input", "id"]]),
      issue_mutation_target(query, variables, "commentCreate", [["issueId"], ["issue_id"], ["input", "issueId"], ["input", "issue_id"]]),
      issue_mutation_target(query, variables, "issueAttachmentCreate", [
        ["issueId"],
        ["issue_id"],
        ["input", "issueId"],
        ["input", "issue_id"]
      ]),
      issue_mutation_target(query, variables, "issueRelationCreate", [
        ["issueId"],
        ["issue_id"],
        ["relatedIssueId"],
        ["related_issue_id"],
        ["input", "issueId"],
        ["input", "issue_id"],
        ["input", "relatedIssueId"],
        ["input", "related_issue_id"]
      ]),
      comment_mutation_target(query, variables, "commentUpdate"),
      comment_mutation_target(query, variables, "commentDelete"),
      project_mutation_target(query, variables, "issueCreate")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp issue_mutation_target(query, variables, mutation_name, paths) do
    if String.contains?(query, mutation_name) do
      issue_ids =
        issue_target_variable_values(variables, paths)
        |> Kernel.++(inline_values(query, ~r/issueId\s*:\s*"([^"]+)"/))
        |> Kernel.++(
          if mutation_name == "issueUpdate",
            do: inline_values(query, ~r/issueUpdate\s*\(\s*id\s*:\s*"([^"]+)"/),
            else: []
        )
        |> Enum.uniq()

      if issue_ids == [] do
        [{:unverified, mutation_name}]
      else
        Enum.map(issue_ids, &{:issue, &1})
      end
    end
  end

  defp issue_target_variable_values(variables, paths) do
    Enum.flat_map(paths, fn path ->
      variables
      |> variable_value([path])
      |> string_list()
    end)
  end

  defp string_list(nil), do: []
  defp string_list(value), do: [to_string(value)]

  defp comment_mutation_target(query, variables, mutation_name) do
    if String.contains?(query, mutation_name) do
      comment_ids =
        variables
        |> variable_value([[mutation_name_id_key(mutation_name)], ["commentId"], ["comment_id"], ["id"], ["input", "id"]])
        |> case do
          nil -> inline_values(query, ~r/#{mutation_name}\s*\(\s*id\s*:\s*"([^"]+)"/)
          value -> [to_string(value)]
        end
        |> Enum.uniq()

      if comment_ids == [] do
        [{:unverified, mutation_name}]
      else
        Enum.map(comment_ids, &{:comment, &1})
      end
    end
  end

  defp mutation_name_id_key("commentUpdate"), do: "commentUpdateId"
  defp mutation_name_id_key("commentDelete"), do: "commentDeleteId"

  defp project_mutation_target(query, variables, mutation_name) do
    if String.contains?(query, mutation_name) do
      project_ids =
        variables
        |> variable_value([["projectId"], ["project_id"], ["input", "projectId"], ["input", "project_id"]])
        |> case do
          nil -> inline_values(query, ~r/projectId\s*:\s*"([^"]+)"/)
          value -> [to_string(value)]
        end
        |> Enum.uniq()

      if project_ids == [] do
        [{:unverified, mutation_name}]
      else
        Enum.map(project_ids, &{:project, &1})
      end
    end
  end

  defp authorize_linear_mutation_targets([], _linear_client), do: :ok

  defp authorize_linear_mutation_targets(targets, linear_client) when is_list(targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case authorize_linear_mutation_target(target, linear_client) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp authorize_linear_mutation_target({:issue, issue_id}, linear_client) do
    with {:ok, response} <- linear_client.(@linear_scope_issue_query, %{"issueId" => issue_id}, []) do
      verify_scoped_issue_payload(payload_value(response, ["data", "issue"]), "issue", issue_id)
    end
  end

  defp authorize_linear_mutation_target({:comment, comment_id}, linear_client) do
    with {:ok, response} <- linear_client.(@linear_scope_comment_query, %{"commentId" => comment_id}, []) do
      verify_scoped_issue_payload(payload_value(response, ["data", "comment", "issue"]), "comment", comment_id)
    end
  end

  defp authorize_linear_mutation_target({:project, project_id}, linear_client) do
    selected_project_slug = Config.settings!().tracker.project_slug

    with {:ok, response} <- linear_client.(@linear_scope_project_query, %{"projectSlug" => selected_project_slug}, []) do
      project = payload_value(response, ["data", "projects", "nodes"]) |> List.wrap() |> List.first()

      if payload_value(project, ["id"]) == project_id do
        :ok
      else
        linear_scope_error("Blocked Linear mutation: target project is outside the active Symphony project.", %{
          "projectId" => project_id,
          "selectedProjectSlug" => selected_project_slug
        })
      end
    end
  end

  defp authorize_linear_mutation_target({:unverified, mutation_name}, _linear_client) do
    linear_scope_error("Blocked Linear mutation: Symphony could not verify the target scope.", %{
      "mutation" => mutation_name
    })
  end

  defp verify_scoped_issue_payload(issue, target_type, target_id) when is_map(issue) do
    selected_project_slug = Config.settings!().tracker.project_slug
    issue_project_slug = payload_value(issue, ["project", "slugId"])

    if ProjectScope.matches_slug?(selected_project_slug, issue_project_slug) do
      :ok
    else
      linear_scope_error("Blocked Linear mutation: target #{target_type} is outside the active Symphony project.", %{
        "targetType" => target_type,
        "targetId" => target_id,
        "issueIdentifier" => payload_value(issue, ["identifier"]),
        "issueProjectSlug" => issue_project_slug,
        "selectedProjectSlug" => selected_project_slug
      })
    end
  end

  defp verify_scoped_issue_payload(_issue, target_type, target_id) do
    linear_scope_error("Blocked Linear mutation: Symphony could not verify the target #{target_type}.", %{
      "targetType" => target_type,
      "targetId" => target_id
    })
  end

  defp linear_scope_error(message, details), do: {:error, {:linear_scope_blocked, message, details}}

  defp authorize_issue_state_update(query, variables, opts, linear_client) do
    with {:ok, issue_id, state_id} <- issue_state_update_ids(query, variables),
         {:ok, target} <- fetch_target_state(linear_client, issue_id, state_id) do
      authorize_target_state(opts, target)
    end
  end

  defp authorize_target_state(opts, target) do
    if review_state?(target.state_name) do
      verify_review_ready(opts, target)
    else
      :ok
    end
  end

  defp review_guard_required?(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) ->
        File.exists?(Path.join(workspace, ".symphony/review-ready-required")) or
          File.exists?(Path.join(workspace, "scripts/review_readiness_check.mjs"))

      _ ->
        false
    end
  end

  defp issue_state_update_query?(query) do
    String.contains?(query, "issueUpdate") and String.contains?(query, "stateId")
  end

  defp issue_state_update_ids(query, variables) do
    issue_id =
      variable_value(variables, [["issueId"], ["issue_id"], ["id"], ["input", "id"]]) ||
        inline_value(query, ~r/issueUpdate\s*\(\s*id\s*:\s*"([^"]+)"/)

    state_id =
      variable_value(variables, [["stateId"], ["state_id"], ["input", "stateId"], ["input", "state_id"]]) ||
        inline_value(query, ~r/stateId\s*:\s*"([^"]+)"/)

    cond do
      is_nil(issue_id) or String.trim(to_string(issue_id)) == "" ->
        review_transition_error("Blocked Linear state update: Symphony could not identify the target issue for review gating.", %{
          "missing" => "issue id"
        })

      is_nil(state_id) or String.trim(to_string(state_id)) == "" ->
        review_transition_error("Blocked Linear state update: Symphony could not identify the target state for review gating.", %{
          "missing" => "state id"
        })

      true ->
        {:ok, to_string(issue_id), to_string(state_id)}
    end
  end

  defp variable_value(variables, paths) do
    Enum.find_value(paths, fn path ->
      nested_value(variables, path)
    end)
  end

  defp nested_value(value, []), do: value

  defp nested_value(value, [key | rest]) when is_map(value) do
    case map_value(value, key) do
      nil -> nil
      next -> nested_value(next, rest)
    end
  end

  defp nested_value(_value, _path), do: nil

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> nil
    end
  end

  defp inline_value(query, regex) do
    case Regex.run(regex, query) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp inline_values(query, regex) do
    Regex.scan(regex, query, capture: :all_but_first)
    |> List.flatten()
  end

  defp fetch_target_state(linear_client, issue_id, state_id) do
    case linear_client.(@review_state_guard_query, %{"issueId" => issue_id}, []) do
      {:ok, response} ->
        issue = payload_value(response, ["data", "issue"])
        states = payload_value(issue, ["team", "states", "nodes"]) || []

        state =
          Enum.find(states, fn candidate ->
            payload_value(candidate, ["id"]) == state_id
          end)

        if is_map(issue) and is_map(state) do
          {:ok,
           %{
             issue_id: payload_value(issue, ["id"]),
             issue_identifier: payload_value(issue, ["identifier"]),
             state_id: state_id,
             state_name: payload_value(state, ["name"])
           }}
        else
          review_transition_error("Blocked Linear state update: Symphony could not verify the target Linear state.", %{
            "issueId" => issue_id,
            "stateId" => state_id
          })
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp payload_value(value, path), do: nested_value(value, path)

  defp review_state?(state_name) when is_binary(state_name) do
    MapSet.member?(@review_state_names, String.downcase(String.trim(state_name)))
  end

  defp review_state?(_state_name), do: false

  defp verify_review_ready(opts, target) do
    workspace = Keyword.get(opts, :workspace)
    issue = Keyword.get(opts, :issue)

    with :ok <- verify_workspace_for_review(workspace),
         :ok <- ensure_no_review_blockers(workspace),
         {:ok, proof} <- read_review_ready_proof(workspace) do
      validate_review_ready_proof(proof, workspace, issue, target, opts)
    end
  end

  defp verify_workspace_for_review(workspace) when is_binary(workspace), do: :ok

  defp verify_workspace_for_review(_workspace) do
    review_transition_error("Blocked review transition: no workspace context was available for readiness verification.", %{})
  end

  defp ensure_no_review_blockers(workspace) do
    blockers =
      @review_blocker_files
      |> Enum.map(&Path.join(workspace, &1))
      |> Enum.filter(&File.exists?/1)

    if blockers == [] do
      :ok
    else
      review_transition_error("Blocked review transition: a live gate blocker marker is still present.", %{
        "blockers" => blockers
      })
    end
  end

  defp read_review_ready_proof(workspace) do
    marker_path = Path.join(workspace, @review_ready_file)

    case File.read(marker_path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, proof} when is_map(proof) ->
            {:ok, Map.put(proof, "_path", marker_path)}

          _ ->
            review_transition_error("Blocked review transition: readiness proof is not valid JSON.", %{
              "path" => marker_path
            })
        end

      {:error, _reason} ->
        review_transition_error("Blocked review transition: missing review readiness proof.", %{
          "path" => marker_path,
          "requiredCommand" => "Run the configured review readiness check; it must write this file on pass."
        })
    end
  end

  defp validate_review_ready_proof(proof, workspace, issue, target, opts) do
    expected_issue =
      issue_identifier(issue) ||
        target.issue_identifier ||
        target.issue_id

    with :ok <- validate_review_ready_identity(proof, expected_issue, target),
         :ok <- validate_review_ready_flags(proof),
         :ok <- validate_acceptance_agent_review(proof, workspace, expected_issue, target, opts) do
      validate_review_ready_head(proof, workspace, opts)
    end
  end

  defp validate_review_ready_identity(proof, expected_issue, target) do
    cond do
      proof_value(proof, "schema") != "symphony.review-ready.v1" ->
        review_transition_error("Blocked review transition: readiness proof has an unsupported schema.", %{
          "path" => proof["_path"]
        })

      proof_value(proof, "issue") not in Enum.reject([expected_issue, target.issue_identifier, target.issue_id], &is_nil/1) ->
        review_transition_error("Blocked review transition: readiness proof belongs to a different issue.", %{
          "path" => proof["_path"],
          "proofIssue" => proof_value(proof, "issue"),
          "expectedIssue" => expected_issue
        })

      true ->
        :ok
    end
  end

  defp validate_review_ready_flags(proof) do
    with :ok <- require_true_proof_fields(proof, required_review_ready_fields()),
         :ok <- validate_review_recipe_access(proof),
         :ok <- require_true_proof_fields(proof, user_facing_review_ready_fields(proof)) do
      validate_review_branch(proof)
    end
  end

  defp required_review_ready_fields do
    [
      "reviewReadinessCheckPassed",
      "workpadCompleted",
      "reviewRecipeAccessible",
      "developmentBranchReviewed",
      "sharedBranchCommitted",
      "targetContainsSharedBranchCommit",
      "validationPassed",
      "deliverableReviewPassed"
    ]
  end

  defp user_facing_review_ready_fields(proof) do
    if proof_user_facing?(proof) do
      ["functionalReviewRecipePassed", "screenshotArtifactVerified"]
    else
      []
    end
  end

  defp require_true_proof_fields(proof, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      if proof_value(proof, field) == true do
        {:cont, :ok}
      else
        {:halt, missing_proof_field(proof, field)}
      end
    end)
  end

  defp validate_review_recipe_access(proof) do
    case proof_value(proof, "reviewRecipeUrl") do
      url when is_binary(url) and url != "" ->
        case ReviewRecipe.validate_accessible_url(url) do
          {:ok, _url} ->
            :ok

          {:error, details} ->
            details =
              details
              |> stringify_keys()
              |> Map.put("field", "reviewRecipeUrl")
              |> Map.put("path", proof["_path"])

            review_transition_error(
              "Blocked review transition: reviewRecipeUrl is not reviewer-accessible.",
              details
            )
        end

      _ ->
        review_transition_error("Blocked review transition: readiness proof is missing an accessible reviewRecipeUrl.", %{
          "field" => "reviewRecipeUrl",
          "path" => proof["_path"]
        })
    end
  end

  defp validate_review_branch(proof) do
    expected_branch = development_branch()

    if proof_review_branch(proof) == expected_branch do
      :ok
    else
      review_transition_error("Blocked review transition: readiness proof did not review the configured development branch.", %{
        "path" => proof["_path"],
        "reviewBranch" => proof_review_branch(proof),
        "expectedBranch" => expected_branch
      })
    end
  end

  defp validate_acceptance_agent_review(proof, workspace, expected_issue, target, opts) do
    if proof_user_facing?(proof) do
      with {:ok, review} <- read_acceptance_agent_review(proof, workspace),
           :ok <- validate_acceptance_agent_issue(review, expected_issue, target),
           :ok <- validate_acceptance_agent_fields(review) do
        validate_acceptance_agent_head(review, workspace, opts)
      end
    else
      :ok
    end
  end

  defp read_acceptance_agent_review(proof, workspace) do
    case proof_value(proof, "acceptanceAgentReview") || proof_value(proof, "acceptanceAgent") do
      review when is_map(review) ->
        {:ok, Map.put_new(review, "_path", proof["_path"])}

      _ ->
        read_acceptance_agent_review_file(workspace)
    end
  end

  defp read_acceptance_agent_review_file(workspace) do
    review_path = Path.join(workspace, @acceptance_agent_review_file)

    case File.read(review_path) do
      {:ok, body} -> decode_acceptance_agent_review(body, review_path)
      {:error, _reason} -> missing_acceptance_agent_review(review_path)
    end
  end

  defp decode_acceptance_agent_review(body, review_path) do
    case Jason.decode(body) do
      {:ok, review} when is_map(review) ->
        {:ok, Map.put(review, "_path", review_path)}

      _ ->
        review_transition_error("Blocked review transition: independent acceptance agent proof is not valid JSON.", %{
          "path" => review_path
        })
    end
  end

  defp missing_acceptance_agent_review(review_path) do
    review_transition_error("Blocked review transition: missing independent acceptance agent proof.", %{
      "path" => review_path,
      "requiredEvidence" => "Run an observe-only browser acceptance review on the live #{development_branch()} deployment and record a pass verdict before review."
    })
  end

  defp validate_acceptance_agent_issue(review, expected_issue, target) do
    candidates = Enum.reject([expected_issue, target.issue_identifier, target.issue_id], &is_nil/1)

    if proof_value(review, "issue") in candidates do
      :ok
    else
      review_transition_error("Blocked review transition: independent acceptance agent proof belongs to a different issue.", %{
        "path" => review["_path"],
        "proofIssue" => proof_value(review, "issue"),
        "expectedIssue" => expected_issue
      })
    end
  end

  defp validate_acceptance_agent_fields(review) do
    with :ok <- validate_acceptance_agent_schema(review),
         :ok <- require_true_acceptance_agent_fields(review, required_acceptance_agent_fields()) do
      validate_acceptance_agent_evidence(review)
    end
  end

  defp validate_acceptance_agent_schema(review) do
    cond do
      proof_value(review, "schema") != @acceptance_agent_review_schema ->
        review_transition_error("Blocked review transition: independent acceptance agent proof has an unsupported schema.", %{
          "path" => review["_path"],
          "schema" => proof_value(review, "schema")
        })

      acceptance_agent_verdict(review) != "pass" ->
        review_transition_error("Blocked review transition: independent acceptance agent did not pass the ticket.", %{
          "path" => review["_path"],
          "verdict" => proof_value(review, "verdict")
        })

      true ->
        :ok
    end
  end

  defp required_acceptance_agent_fields do
    [
      "testedLiveMain",
      "browserTested",
      "observeOnly",
      "claimsExtracted",
      "visibleClaimsVerified",
      "regressionClaimsVerified",
      "deterministicValidatorsOnlySupportingEvidence"
    ]
  end

  defp require_true_acceptance_agent_fields(review, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      if proof_value(review, field) == true do
        {:cont, :ok}
      else
        {:halt, missing_acceptance_agent_field(review, field)}
      end
    end)
  end

  defp validate_acceptance_agent_evidence(review) do
    cond do
      not acceptance_agent_claims_passed?(review) ->
        missing_acceptance_agent_field(review, "claims")

      not acceptance_agent_evidence_present?(review) ->
        missing_acceptance_agent_field(review, "evidence")

      true ->
        :ok
    end
  end

  defp acceptance_agent_verdict(review) do
    review
    |> proof_value("verdict")
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp acceptance_agent_evidence_present?(review) do
    case proof_value(review, "evidence") do
      value when is_binary(value) -> String.trim(value) != ""
      value when is_list(value) -> Enum.any?(value, &acceptance_agent_evidence_value?/1)
      value when is_map(value) -> value |> Map.values() |> Enum.any?(&acceptance_agent_evidence_value?/1)
      _ -> false
    end
  end

  defp acceptance_agent_evidence_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp acceptance_agent_evidence_value?(value) when is_list(value), do: Enum.any?(value, &acceptance_agent_evidence_value?/1)
  defp acceptance_agent_evidence_value?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&acceptance_agent_evidence_value?/1)
  defp acceptance_agent_evidence_value?(_value), do: false

  defp acceptance_agent_claims_passed?(review) do
    case proof_value(review, "claims") do
      claims when is_list(claims) and claims != [] ->
        Enum.all?(claims, &acceptance_agent_claim_passed?/1)

      _ ->
        false
    end
  end

  defp acceptance_agent_claim_passed?(%{} = claim) do
    acceptance_agent_evidence_value?(proof_value(claim, "claim")) and
      acceptance_agent_claim_status(claim) == "pass" and
      acceptance_agent_evidence_value?(proof_value(claim, "evidence"))
  end

  defp acceptance_agent_claim_passed?(_claim), do: false

  defp acceptance_agent_claim_status(claim) do
    claim
    |> proof_value("status")
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp validate_acceptance_agent_head(review, workspace, opts) do
    case workspace_head(workspace, opts) do
      {:ok, head} ->
        if proof_value(review, "workspaceHead") == head do
          :ok
        else
          review_transition_error("Blocked review transition: independent acceptance agent proof does not match the current workspace HEAD.", %{
            "path" => review["_path"],
            "proofHead" => proof_value(review, "workspaceHead"),
            "currentHead" => head
          })
        end

      {:error, reason} ->
        review_transition_error("Blocked review transition: could not verify current workspace HEAD for independent acceptance proof.", %{
          "path" => review["_path"],
          "reason" => inspect(reason)
        })
    end
  end

  defp validate_review_ready_head(proof, workspace, opts) do
    case workspace_head(workspace, opts) do
      {:ok, head} ->
        if proof_value(proof, "workspaceHead") == head do
          :ok
        else
          review_transition_error("Blocked review transition: readiness proof does not match the current workspace HEAD.", %{
            "path" => proof["_path"],
            "proofHead" => proof_value(proof, "workspaceHead"),
            "currentHead" => head
          })
        end

      {:error, reason} ->
        review_transition_error("Blocked review transition: could not verify current workspace HEAD.", %{
          "path" => proof["_path"],
          "reason" => inspect(reason)
        })
    end
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp issue_identifier(_issue), do: nil

  defp proof_value(proof, key) do
    case fetch_map_value(proof, key) do
      {:ok, value} -> value
      :error -> map_value(proof, Macro.underscore(key))
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    atom_key = String.to_atom(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.get(map, atom_key)}
      true -> :error
    end
  end

  defp proof_review_branch(proof) do
    proof_value(proof, "reviewBranch") || proof_value(proof, "expectedBranch")
  end

  defp development_branch do
    case Config.selected_repository() do
      %{branch: branch} when is_binary(branch) ->
        case String.trim(branch) do
          "" -> "develop"
          trimmed -> trimmed
        end

      _ ->
        "develop"
    end
  end

  defp proof_user_facing?(proof) do
    proof_value(proof, "userFacing") != false
  end

  defp workspace_head(workspace, opts) do
    case Keyword.fetch(opts, :git_head) do
      {:ok, head} when is_binary(head) and head != "" ->
        {:ok, head}

      _ ->
        workspace_head(workspace)
    end
  end

  defp workspace_head(workspace) when is_binary(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true) do
      {head, 0} -> {:ok, String.trim(head)}
      {output, status} -> {:error, {:git_rev_parse_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  defp workspace_head(_workspace), do: {:error, :missing_workspace}

  defp missing_proof_field(proof, field) do
    review_transition_error("Blocked review transition: readiness proof is missing a passing #{field} flag.", %{
      "path" => proof["_path"],
      "field" => field
    })
  end

  defp missing_acceptance_agent_field(review, field) do
    review_transition_error("Blocked review transition: independent acceptance agent proof is missing a passing #{field} field.", %{
      "path" => review["_path"],
      "field" => field
    })
  end

  defp review_transition_error(message, details) do
    {:error, {:review_transition_blocked, message, details}}
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `tracker.api_key`/`LINEAR_API_KEY` or `tracker.oauth_access_token`/`LINEAR_OAUTH_ACCESS_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_scope_blocked, message, details}) do
    %{
      "error" => %{
        "message" => message,
        "details" => details
      }
    }
  end

  defp tool_error_payload({:review_transition_blocked, message, details}) do
    %{
      "error" => %{
        "message" => message,
        "details" => details
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp jira_tool_error_payload(:missing_jira_issue) do
    %{
      "error" => %{
        "message" => "`jira_issue_attachments` requires a Jira issue key or browse URL in `issue`."
      }
    }
  end

  defp jira_tool_error_payload(:invalid_jira_arguments) do
    %{
      "error" => %{
        "message" => "`jira_issue_attachments` expects an object with `issue`, optional `filename_contains`, and optional `download`."
      }
    }
  end

  defp jira_tool_error_payload({:invalid_jira_argument, key}) do
    %{
      "error" => %{
        "message" => "`jira_issue_attachments.#{key}` has an invalid type."
      }
    }
  end

  defp jira_tool_error_payload(:missing_jira_auth) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira auth. Set `jira.email` and `jira.api_token` in `WORKFLOW.md` or export `JIRA_EMAIL` and `JIRA_API_TOKEN`."
      }
    }
  end

  defp jira_tool_error_payload(:missing_jira_site) do
    %{
      "error" => %{
        "message" => "Symphony is missing Jira site. Pass a Jira browse URL or set `jira.site` in `WORKFLOW.md` / `JIRA_SITE`."
      }
    }
  end

  defp jira_tool_error_payload({:jira_api_status, status}) do
    %{
      "error" => %{
        "message" => "Jira issue request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp jira_tool_error_payload({:jira_attachment_status, status, filename}) do
    %{
      "error" => %{
        "message" => "Jira attachment download failed with HTTP #{status}.",
        "status" => status,
        "filename" => filename
      }
    }
  end

  defp jira_tool_error_payload({:jira_remote_workspace_unsupported, worker_host}) do
    %{
      "error" => %{
        "message" => "Jira attachment downloads require a local workspace; remote worker downloads are not supported yet.",
        "workerHost" => worker_host
      }
    }
  end

  defp jira_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Jira attachment tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    (tool_specs() ++ comment_reply_tool_specs())
    |> Enum.map(& &1["name"])
    |> Enum.uniq()
  end
end
