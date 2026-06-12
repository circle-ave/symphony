defmodule SymphonyElixir.ReviewRecipe do
  @moduledoc false

  @active_workpad_header "## Codex Workpad"
  @superseded_workpad_header "## Superseded Codex Workpad"

  @not_found_markers [
    "404",
    "not found",
    "could not find what you were looking for"
  ]

  @spec prepare([map()]) :: {:ok, map()} | {:error, map()}
  def prepare(comments) when is_list(comments) do
    active_workpads =
      comments
      |> Enum.filter(&active_workpad?/1)

    case active_workpads do
      [] ->
        {:error, %{reason: :missing_workpad}}

      [workpad] ->
        with {:ok, section} <- demo_recipe_section(field(workpad, "body")),
             {:ok, url} <- extract_open_url(section),
             {:ok, credentials} <- extract_credentials(section),
             {:ok, claims} <- extract_claims(section) do
          {:ok,
           %{
             workpad_id: field(workpad, "id"),
             url: url,
             claims: claims,
             lane_action: :human_owned
           }
           |> maybe_put_credentials(credentials)}
        end

      duplicates ->
        {:error,
         %{
           reason: :multiple_workpads,
           workpad_ids: Enum.map(duplicates, &field(&1, "id"))
         }}
    end
  end

  def prepare(_comments), do: {:error, %{reason: :invalid_comments}}

  @spec evaluate(map(), map()) :: map()
  def evaluate(%{url: expected_url, claims: claims} = recipe, observation)
      when is_map(observation) and is_list(claims) do
    current_url = observation_field(observation, "url") || ""
    title = observation_field(observation, "title") || ""
    content = observation_content(observation)
    console_entries = observation_console_entries(observation)

    failures =
      []
      |> maybe_add(login_redirect?(current_url, title), :login_redirect)
      |> maybe_add(not_found?(content), :not_found)
      |> maybe_add(wrong_route?(expected_url, current_url), :wrong_route)
      |> add_missing_claims(claims, content)
      |> add_console_entries(console_entries)
      |> Enum.reverse()

    %{
      verdict: if(failures == [], do: :pass, else: :fail),
      failures: failures,
      expected_url: expected_url,
      observed_url: current_url,
      claims_checked: claims,
      lane_action: Map.get(recipe, :lane_action, :human_owned)
    }
  end

  def evaluate(_recipe, _observation) do
    %{
      verdict: :fail,
      failures: [%{reason: :invalid_observation}],
      lane_action: :human_owned
    }
  end

  defp active_workpad?(comment) do
    body = field(comment, "body")

    is_binary(body) and
      String.starts_with?(body, @active_workpad_header) and
      not String.starts_with?(body, @superseded_workpad_header)
  end

  defp demo_recipe_section(body) when is_binary(body) do
    lines = String.split(body, ~r/\R/)
    index = Enum.find_index(lines, &(String.trim(&1) == "### Demo / Review Recipe"))

    if is_integer(index) do
      section =
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "### ")))
        |> Enum.join("\n")
        |> String.trim()

      if section == "" do
        {:error, %{reason: :empty_demo_review_recipe}}
      else
        {:ok, section}
      end
    else
      {:error, %{reason: :missing_demo_review_recipe}}
    end
  end

  defp demo_recipe_section(_body), do: {:error, %{reason: :missing_demo_review_recipe}}

  defp extract_open_url(section) do
    open_line =
      section
      |> String.split(~r/\R/)
      |> Enum.find(&String.match?(&1, ~r/^\s*-\s*Open:/i))

    source = open_line || section

    case Regex.run(~r/https?:\/\/[^\s<>)\]]+/, source) do
      [url] -> {:ok, trim_url(url)}
      _ -> {:error, %{reason: :missing_review_url}}
    end
  end

  defp extract_claims(section) do
    verify_text =
      section
      |> String.split(~r/\R/)
      |> Enum.filter(&String.match?(&1, ~r/^\s*-\s*Verify:/i))
      |> Enum.join("\n")

    claims =
      case backtick_values(verify_text) do
        [] -> section |> remove_credential_lines() |> backtick_values()
        values -> values
      end
      |> Enum.reject(&String.starts_with?(&1, "http"))
      |> Enum.uniq()

    if claims == [] do
      {:error, %{reason: :missing_visible_claims}}
    else
      {:ok, claims}
    end
  end

  defp backtick_values(text) do
    ~r/`([^`]+)`/
    |> Regex.scan(text)
    |> Enum.map(fn [_match, value] -> String.trim(value) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_credentials(section) do
    username = extract_credential_value(section, ["Username", "User", "Login username"])
    password = extract_credential_value(section, ["Password", "Pass", "Login password"])
    inline_username = extract_inline_credential_value(section, ~r/(?:username|user|email)/i)
    inline_password = extract_inline_credential_value(section, ~r/(?:password|pass)/i)

    username = username || inline_username
    password = password || inline_password

    cond do
      is_binary(username) and is_binary(password) ->
        {:ok, %{username: username, password: password}}

      credentials_required?(section) ->
        {:error, %{reason: :missing_credentials}}

      is_binary(username) or is_binary(password) ->
        {:error, %{reason: :incomplete_credentials}}

      true ->
        {:ok, nil}
    end
  end

  defp extract_credential_value(section, labels) do
    section
    |> String.split(~r/\R/)
    |> Enum.find_value(fn line ->
      label = Enum.find(labels, &credential_label_line?(line, &1))
      if label, do: line |> credential_line_value(label) |> clean_credential_value()
    end)
  end

  defp credential_label_line?(line, label) do
    Regex.match?(~r/^\s*-\s*#{Regex.escape(label)}\s*:/i, line)
  end

  defp credential_line_value(line, label) do
    Regex.replace(~r/^\s*-\s*#{Regex.escape(label)}\s*:\s*/i, line, "")
  end

  defp extract_inline_credential_value(section, label_regex) do
    section
    |> String.split(~r/\R/)
    |> Enum.filter(&credential_container_line?/1)
    |> Enum.find_value(&extract_named_value(&1, label_regex))
  end

  defp credential_container_line?(line) do
    Regex.match?(~r/^\s*-\s*(?:Login|Auth|Credentials)\s*:/i, line)
  end

  defp extract_named_value(line, label_regex) do
    regexes = [
      ~r/#{Regex.source(label_regex)}\s*[:=]?\s*`([^`]+)`/i,
      ~r/#{Regex.source(label_regex)}\s*[:=]\s*([^\s;,]+)/i
    ]

    Enum.find_value(regexes, fn regex ->
      case Regex.run(regex, line) do
        [_match, value] -> clean_credential_value(value)
        _ -> nil
      end
    end)
  end

  defp clean_credential_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.trim_trailing(",")
    |> String.trim_trailing(";")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp credentials_required?(section) do
    no_auth? =
      Regex.match?(
        ~r/(?:login|auth|authentication)\s*:\s*`?not required`?|no (?:login|auth|authentication) required/i,
        section
      )

    required? =
      Regex.match?(
        ~r/(?:login|auth|authentication)\s*:\s*`?required`?|(?:login|auth|authentication) required|requires (?:login|auth|authentication)|sign in required/i,
        section
      )

    required? and not no_auth?
  end

  defp remove_credential_lines(section) do
    section
    |> String.split(~r/\R/)
    |> Enum.reject(&credential_line?/1)
    |> Enum.join("\n")
  end

  defp credential_line?(line) do
    Regex.match?(~r/^\s*-\s*(?:Username|User|Login username|Password|Pass|Login password|Login|Auth|Credentials)\s*:/i, line)
  end

  defp maybe_put_credentials(recipe, nil), do: recipe
  defp maybe_put_credentials(recipe, credentials), do: Map.put(recipe, :credentials, credentials)

  defp trim_url(url), do: Regex.replace(~r/[`.,;]+$/, url, "")

  defp login_redirect?(url, title) do
    String.contains?(String.downcase(url), "/login") or
      String.downcase(String.trim(title)) == "login"
  end

  defp not_found?(content) do
    downcased = String.downcase(content)
    Enum.any?(@not_found_markers, &String.contains?(downcased, &1))
  end

  defp wrong_route?(expected_url, current_url) do
    with %URI{host: expected_host, path: expected_path} when is_binary(expected_host) <-
           URI.parse(expected_url),
         %URI{host: current_host, path: current_path} when is_binary(current_host) <-
           URI.parse(current_url) do
      expected_host != current_host or normalize_path(expected_path) != normalize_path(current_path)
    else
      _ -> true
    end
  end

  defp normalize_path(path) when is_binary(path), do: URI.decode(path)
  defp normalize_path(_path), do: ""

  defp add_missing_claims(failures, claims, content) do
    missing =
      claims
      |> Enum.reject(&String.contains?(content, &1))

    if missing == [] do
      failures
    else
      [%{reason: :missing_claims, claims: missing} | failures]
    end
  end

  defp add_console_entries(failures, []), do: failures

  defp add_console_entries(failures, entries) do
    [%{reason: :console_warnings_or_errors, entries: entries} | failures]
  end

  defp maybe_add(failures, true, reason), do: [%{reason: reason} | failures]
  defp maybe_add(failures, false, _reason), do: failures

  defp observation_content(observation) do
    [
      observation_field(observation, "visible_text"),
      observation_field(observation, "dom_snapshot"),
      observation_field(observation, "body")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp observation_console_entries(observation) do
    []
    |> Kernel.++(List.wrap(observation_field(observation, "console_errors")))
    |> Kernel.++(List.wrap(observation_field(observation, "console_warnings")))
    |> Enum.reject(&is_nil/1)
  end

  defp observation_field(map, field), do: Map.get(map, field) || Map.get(map, String.to_atom(field))

  defp field(map, field) when is_map(map), do: Map.get(map, field) || Map.get(map, String.to_atom(field))
  defp field(_map, _field), do: nil
end
