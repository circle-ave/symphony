defmodule SymphonyElixir.JiraClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Client

  test "downloads matching Jira issue attachments into the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-jira-attachments-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        jira_email: "agent@example.com",
        jira_api_token: "jira-token"
      )

      test_pid = self()

      http_client = fn opts ->
        url = Keyword.fetch!(opts, :url)
        headers = Keyword.fetch!(opts, :headers)
        send(test_pid, {:jira_request, url, headers})

        cond do
          String.contains?(url, "/rest/api/3/issue/TP-24") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "fields" => %{
                   "attachment" => [
                     %{
                       "id" => "att-1",
                       "filename" => "Screenshot 2026-04-03 at 1.01.19 PM.png",
                       "mimeType" => "image/png",
                       "size" => 12_345,
                       "content" => "https://circleavenue.atlassian.net/secure/attachment/att-1/screenshot.png"
                     },
                     %{
                       "id" => "att-2",
                       "filename" => "notes.txt",
                       "mimeType" => "text/plain",
                       "size" => 123,
                       "content" => "https://circleavenue.atlassian.net/secure/attachment/att-2/notes.txt"
                     }
                   ]
                 }
               }
             }}

          String.contains?(url, "/secure/attachment/att-1/") ->
            {:ok, %{status: 200, body: "png-bytes"}}
        end
      end

      assert {:ok, result} =
               Client.issue_attachments(
                 %{
                   "issue" => "https://circleavenue.atlassian.net/browse/TP-24",
                   "filename_contains" => "Screenshot"
                 },
                 workspace: workspace,
                 http_client: http_client
               )

      assert result["issue"] == "TP-24"
      assert result["attachmentCount"] == 1

      [attachment] = result["attachments"]
      assert attachment["filename"] == "Screenshot 2026-04-03 at 1.01.19 PM.png"
      assert attachment["path"] =~ "/.symphony/jira-attachments/TP-24/"
      assert File.read!(attachment["path"]) == "png-bytes"

      expected_auth = "Basic " <> Base.encode64("agent@example.com:jira-token")
      assert_received {:jira_request, "https://circleavenue.atlassian.net/rest/api/3/issue/TP-24?fields=attachment", headers}
      assert {"Authorization", ^expected_auth} = List.keyfind(headers, "Authorization", 0)
    after
      File.rm_rf(test_root)
    end
  end
end
