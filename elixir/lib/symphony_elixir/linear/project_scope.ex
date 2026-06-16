defmodule SymphonyElixir.Linear.ProjectScope do
  @moduledoc false

  @spec matches_slug?(String.t() | nil, String.t() | nil) :: boolean()
  def matches_slug?(selected_project_slug, issue_project_slug)
      when is_binary(selected_project_slug) and is_binary(issue_project_slug) do
    selected_project_slug = String.trim(selected_project_slug)
    issue_project_slug = String.trim(issue_project_slug)

    selected_project_slug != "" and issue_project_slug != "" and
      (selected_project_slug == issue_project_slug or
         String.ends_with?(selected_project_slug, "-" <> issue_project_slug))
  end

  def matches_slug?(_selected_project_slug, _issue_project_slug), do: false
end
