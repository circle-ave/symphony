defmodule SymphonyElixir.CodexControlsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Controls

  test "exposes command without editable model controls" do
    codex_command =
      "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: codex_command
    )

    assert {:ok, controls} = Controls.current()
    assert controls.command == codex_command
    refute Map.has_key?(controls, :model)
    refute Map.has_key?(controls, :reasoning_effort)
    refute Map.has_key?(controls, :reasoning_effort_options)
  end

  test "updates selected repository controls for future sessions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      repositories_selected: "api",
      repositories_allowed: [
        %{
          id: "api",
          name: "API",
          url: "https://github.com/example/api",
          tracker: %{project_slug: "api-project"}
        },
        %{
          id: "web",
          name: "Web",
          url: "https://github.com/example/web",
          tracker: %{project_slug: "web-project"}
        }
      ]
    )

    assert {:ok, controls} = Controls.current()
    assert controls.selected_repository_id == "api"
    assert Enum.map(controls.repository_options, & &1.id) == ["api", "web"]
    assert Config.settings!().tracker.project_slug == "api-project"

    assert {:ok, updated} = Controls.update(%{"repository_id" => "web"})
    assert updated.selected_repository_id == "web"
    assert Config.settings!().repositories.selected == "web"
    assert Config.settings!().tracker.project_slug == "web-project"
  end

  test "ignores stale model controls without changing codex command" do
    codex_command =
      "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: codex_command
    )

    assert {:ok, controls} =
             Controls.update(%{
               "model" => "gpt-5-mini",
               "reasoning_effort" => "low"
             })

    assert controls.command == codex_command
    assert Config.settings!().codex.command == codex_command

    assert {:ok, workflow} = Workflow.current()
    assert workflow.prompt == "You are an agent for this repository."
  end
end
