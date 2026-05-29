defmodule SymphonyElixir.ReviewRecipeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewRecipe

  test "prepare extracts the current recipe URL and visible claims from one active workpad" do
    comments = [
      %{
        "id" => "old-workpad",
        "body" => "## Superseded Codex Workpad\n\nOld stale URL"
      },
      %{
        "id" => "current-workpad",
        "body" => """
        ## Codex Workpad

        ### Demo / Review Recipe

        - PR/branch: `https://github.com/example/repo/pull/20`
        - Open: `https://law-ep.erpnext.com/app/project/Accomack%20County%20Courthouse%202013`
        - Verify: confirm `Client Info` -> `Metadata` -> `Line Items`, plus `Benefit`, `Time Zone`, and `Contact Phone`

        ### Validation
        """
      }
    ]

    assert {:ok, recipe} = ReviewRecipe.prepare(comments)

    assert recipe.workpad_id == "current-workpad"
    assert recipe.url == "https://law-ep.erpnext.com/app/project/Accomack%20County%20Courthouse%202013"
    assert recipe.lane_action == :human_owned

    assert recipe.claims == [
             "Client Info",
             "Metadata",
             "Line Items",
             "Benefit",
             "Time Zone",
             "Contact Phone"
           ]
  end

  test "prepare rejects duplicate active workpads" do
    comments = [
      %{"id" => "first", "body" => "## Codex Workpad\n\n### Demo / Review Recipe"},
      %{"id" => "second", "body" => "## Codex Workpad\n\n### Demo / Review Recipe"}
    ]

    assert {:error, %{reason: :multiple_workpads, workpad_ids: ["first", "second"]}} =
             ReviewRecipe.prepare(comments)
  end

  test "evaluate passes when browser observation matches route and claims" do
    recipe = %{
      url: "https://law-ep.erpnext.com/app/project/Accomack%20County%20Courthouse%202013",
      claims: ["Client Info", "Metadata", "Line Items"],
      lane_action: :human_owned
    }

    observation = %{
      url: "https://law-ep.erpnext.com/app/project/Accomack%20County%20Courthouse%202013",
      title: "Accomack County Courthouse 2013",
      visible_text: "Client Info\nMetadata\nLine Items",
      console_errors: [],
      console_warnings: []
    }

    assert ReviewRecipe.evaluate(recipe, observation) == %{
             verdict: :pass,
             failures: [],
             expected_url: recipe.url,
             observed_url: observation.url,
             claims_checked: recipe.claims,
             lane_action: :human_owned
           }
  end

  test "evaluate fails stale or wrong recipe pages without moving lanes" do
    recipe = %{
      url: "https://law-ep.erpnext.com/app/project/CIR-54%20Live%20Missing%20Fixture",
      claims: ["Metadata", "Benefit"],
      lane_action: :human_owned
    }

    observation = %{
      url: "https://law-ep.erpnext.com/app/project/CIR-54%20Live%20Missing%20Fixture",
      title: "Frappe",
      visible_text: "Sorry! I could not find what you were looking for.",
      console_errors: [],
      console_warnings: []
    }

    result = ReviewRecipe.evaluate(recipe, observation)

    assert result.verdict == :fail
    assert result.lane_action == :human_owned
    assert %{reason: :not_found} in result.failures
    assert %{reason: :missing_claims, claims: ["Metadata", "Benefit"]} in result.failures
  end

  test "evaluate fails login redirects and console errors" do
    recipe = %{
      url: "https://law-ep.erpnext.com/app/project/Accomack%20County%20Courthouse%202013",
      claims: ["Metadata"]
    }

    observation = %{
      url: "https://law-ep.erpnext.com/login?redirect-to=%2Fapp%2Fproject",
      title: "Login",
      visible_text: "Metadata",
      console_errors: ["Failed request"],
      console_warnings: []
    }

    result = ReviewRecipe.evaluate(recipe, observation)

    assert result.verdict == :fail
    assert %{reason: :login_redirect} in result.failures
    assert %{reason: :wrong_route} in result.failures
    assert %{reason: :console_warnings_or_errors, entries: ["Failed request"]} in result.failures
  end
end
