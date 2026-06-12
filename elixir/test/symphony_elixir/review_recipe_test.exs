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
        - Open: `https://example.test/app/project/alpha`
        - Verify: confirm `Client Info` -> `Metadata` -> `Line Items`, plus `Benefit`, `Time Zone`, and `Contact Phone`

        ### Validation
        """
      }
    ]

    assert {:ok, recipe} = ReviewRecipe.prepare(comments)

    assert recipe.workpad_id == "current-workpad"
    assert recipe.url == "https://example.test/app/project/alpha"
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

  test "prepare extracts review credentials without treating them as visible claims" do
    comments = [
      %{
        "id" => "current-workpad",
        "body" => """
        ## Codex Workpad

        ### Demo / Review Recipe

        - Open: `https://example.test/app/reports/42`
        - Login: required; username `reviewer@example.test`; password `review-pass`
        - Verify: confirm the report shows `Revenue` and `Gross Margin`

        ### Validation
        """
      }
    ]

    assert {:ok, recipe} = ReviewRecipe.prepare(comments)

    assert recipe.credentials == %{username: "reviewer@example.test", password: "review-pass"}
    assert recipe.claims == ["Revenue", "Gross Margin"]
  end

  test "prepare rejects auth-required recipes without username and password" do
    comments = [
      %{
        "id" => "current-workpad",
        "body" => """
        ## Codex Workpad

        ### Demo / Review Recipe

        - Open: `https://example.test/app/reports/42`
        - Login: required
        - Verify: confirm `Revenue`
        """
      }
    ]

    assert {:error, %{reason: :missing_credentials}} = ReviewRecipe.prepare(comments)
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
      url: "https://example.test/app/project/alpha",
      claims: ["Client Info", "Metadata", "Line Items"],
      lane_action: :human_owned
    }

    observation = %{
      url: "https://example.test/app/project/alpha",
      title: "Project Alpha",
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
      url: "https://example.test/app/project/missing-fixture",
      claims: ["Metadata", "Benefit"],
      lane_action: :human_owned
    }

    observation = %{
      url: "https://example.test/app/project/missing-fixture",
      title: "Example App",
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
      url: "https://example.test/app/project/alpha",
      claims: ["Metadata"]
    }

    observation = %{
      url: "https://example.test/login?redirect-to=%2Fapp%2Fproject",
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
