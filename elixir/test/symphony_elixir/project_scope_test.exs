defmodule SymphonyElixir.Linear.ProjectScopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.ProjectScope

  describe "matches_slug?/2" do
    test "accepts exact and URL-prefixed project slugs" do
      assert ProjectScope.matches_slug?("a314e03aa1ba", "a314e03aa1ba")
      assert ProjectScope.matches_slug?("onyx-a314e03aa1ba", "a314e03aa1ba")
      assert ProjectScope.matches_slug?(" onyx-a314e03aa1ba ", " a314e03aa1ba ")
    end

    test "rejects blank, missing, and unrelated project slugs" do
      refute ProjectScope.matches_slug?("", "a314e03aa1ba")
      refute ProjectScope.matches_slug?("onyx-a314e03aa1ba", "")
      refute ProjectScope.matches_slug?(nil, "a314e03aa1ba")
      refute ProjectScope.matches_slug?("onyx-a314e03aa1ba", nil)
      refute ProjectScope.matches_slug?("other-a314e03aa1ba-extra", "a314e03aa1ba")
    end
  end
end
