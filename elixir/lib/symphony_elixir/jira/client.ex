defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Jira REST helpers for issue attachment access.
  """

  alias SymphonyElixir.Config

  @max_attachments 20
  @request_timeout_ms 30_000

  @spec issue_attachments(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_attachments(%{} = params, opts \\ []) do
    jira = Config.settings!().jira
    http_client = Keyword.get(opts, :http_client, &Req.get/1)

    with {:ok, issue_key, site} <- resolve_issue(params, jira),
         {:ok, headers} <- auth_headers(jira),
         {:ok, attachments} <- fetch_issue_attachment_metadata(http_client, site, issue_key, headers),
         attachments <- filter_attachments(attachments, Map.get(params, "filename_contains")),
         {:ok, attachments} <- maybe_download_attachments(attachments, params, issue_key, headers, http_client, opts) do
      {:ok,
       %{
         "issue" => issue_key,
         "site" => site,
         "attachmentCount" => length(attachments),
         "attachments" => attachments
       }}
    end
  end

  defp resolve_issue(params, jira) do
    issue = Map.get(params, "issue")

    with {:ok, issue_key, issue_site} <- parse_issue(issue),
         {:ok, site} <- resolve_site(issue_site, jira.site) do
      {:ok, issue_key, site}
    end
  end

  defp parse_issue(issue) when is_binary(issue) do
    trimmed = String.trim(issue)

    cond do
      trimmed == "" ->
        {:error, :missing_jira_issue}

      String.starts_with?(trimmed, "http://") or String.starts_with?(trimmed, "https://") ->
        parse_issue_url(trimmed)

      String.match?(trimmed, ~r/^[A-Z][A-Z0-9]+-\d+$/) ->
        {:ok, trimmed, nil}

      true ->
        {:error, {:invalid_jira_issue, issue}}
    end
  end

  defp parse_issue(_issue), do: {:error, :missing_jira_issue}

  defp parse_issue_url(url) do
    uri = URI.parse(url)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) <- uri.host,
         issue_key when is_binary(issue_key) <- issue_key_from_path(uri.path) do
      {:ok, issue_key, "#{scheme}://#{host}"}
    else
      _ -> {:error, {:invalid_jira_issue_url, url}}
    end
  end

  defp issue_key_from_path(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> case do
      ["browse", issue_key | _] -> issue_key
      _ -> nil
    end
  end

  defp issue_key_from_path(_path), do: nil

  defp resolve_site(issue_site, configured_site) do
    site =
      configured_site
      |> normalize_string()
      |> case do
        nil -> issue_site
        configured -> configured
      end

    case normalize_site(site) do
      nil -> {:error, :missing_jira_site}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_site(site) when is_binary(site) do
    site
    |> String.trim()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_site(_site), do: nil

  defp auth_headers(jira) do
    with email when is_binary(email) <- normalize_string(jira.email),
         api_token when is_binary(api_token) <- normalize_string(jira.api_token) do
      token = Base.encode64("#{email}:#{api_token}")
      {:ok, [{"Authorization", "Basic #{token}"}, {"Accept", "application/json"}]}
    else
      _ -> {:error, :missing_jira_auth}
    end
  end

  defp fetch_issue_attachment_metadata(http_client, site, issue_key, headers) do
    url = "#{site}/rest/api/3/issue/#{URI.encode(issue_key, &URI.char_unreserved?/1)}?fields=attachment"

    case http_client.(url: url, headers: headers, connect_options: [timeout: @request_timeout_ms]) do
      {:ok, %{status: status, body: %{"fields" => %{"attachment" => attachments}}}} when status in 200..299 and is_list(attachments) ->
        {:ok, Enum.take(attachments, @max_attachments)}

      {:ok, %{status: status}} ->
        {:error, {:jira_api_status, status}}

      {:error, reason} ->
        {:error, {:jira_api_request, reason}}
    end
  end

  defp filter_attachments(attachments, nil), do: normalize_attachments(attachments)

  defp filter_attachments(attachments, filename_contains) when is_binary(filename_contains) do
    needle = filename_contains |> String.trim() |> String.downcase()

    attachments
    |> normalize_attachments()
    |> Enum.filter(fn attachment ->
      needle == "" or String.contains?(String.downcase(attachment["filename"] || ""), needle)
    end)
  end

  defp filter_attachments(attachments, _filename_contains), do: normalize_attachments(attachments)

  defp normalize_attachments(attachments) do
    Enum.map(attachments, fn attachment ->
      %{
        "id" => attachment["id"],
        "filename" => attachment["filename"],
        "mimeType" => attachment["mimeType"],
        "size" => attachment["size"],
        "contentUrl" => attachment["content"]
      }
    end)
  end

  defp maybe_download_attachments(attachments, params, issue_key, headers, http_client, opts) do
    if Map.get(params, "download", true) do
      download_attachments(attachments, issue_key, headers, http_client, opts)
    else
      {:ok, attachments}
    end
  end

  defp download_attachments(attachments, issue_key, headers, http_client, opts) do
    case Keyword.get(opts, :worker_host) do
      worker_host when is_binary(worker_host) ->
        {:error, {:jira_remote_workspace_unsupported, worker_host}}

      _ ->
        download_attachments_to_workspace(attachments, issue_key, headers, http_client, Keyword.get(opts, :workspace))
    end
  end

  defp download_attachments_to_workspace(attachments, issue_key, headers, http_client, workspace)
       when is_binary(workspace) do
    download_dir = Path.join([workspace, ".symphony", "jira-attachments", safe_path_segment(issue_key)])
    File.mkdir_p!(download_dir)

    attachments
    |> Enum.reduce_while({:ok, []}, fn attachment, {:ok, downloaded} ->
      case download_attachment(attachment, download_dir, headers, http_client) do
        {:ok, saved_attachment} -> {:cont, {:ok, [saved_attachment | downloaded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, downloaded} -> {:ok, Enum.reverse(downloaded)}
      error -> error
    end
  end

  defp download_attachments_to_workspace(_attachments, _issue_key, _headers, _http_client, _workspace) do
    {:error, :missing_workspace}
  end

  defp download_attachment(%{"contentUrl" => content_url} = attachment, download_dir, headers, http_client)
       when is_binary(content_url) do
    case http_client.(url: content_url, headers: headers, connect_options: [timeout: @request_timeout_ms]) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        path = Path.join(download_dir, attachment_filename(attachment))
        File.write!(path, body)
        {:ok, attachment |> Map.put("downloaded", true) |> Map.put("path", path)}

      {:ok, %{status: status}} ->
        {:error, {:jira_attachment_status, status, attachment["filename"]}}

      {:error, reason} ->
        {:error, {:jira_attachment_request, reason, attachment["filename"]}}
    end
  end

  defp download_attachment(attachment, _download_dir, _headers, _http_client) do
    {:error, {:jira_attachment_missing_content_url, attachment["filename"]}}
  end

  defp attachment_filename(attachment) do
    id = safe_path_segment(attachment["id"] || "attachment")
    filename = safe_filename(attachment["filename"] || "attachment")
    "#{id}-#{filename}"
  end

  defp safe_filename(filename) do
    filename
    |> Path.basename()
    |> safe_path_segment()
    |> case do
      "" -> "attachment"
      safe -> safe
    end
  end

  defp safe_path_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.trim("_")
  end

  defp safe_path_segment(value), do: value |> to_string() |> safe_path_segment()

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_value), do: nil
end
