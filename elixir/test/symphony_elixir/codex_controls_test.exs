defmodule SymphonyElixir.CodexControlsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Controls

  test "reads model and reasoning effort from codex command flags" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
    )

    assert {:ok, controls} = Controls.current()
    assert controls.model == "gpt-5.5"
    assert controls.reasoning_effort == "xhigh"
    assert controls.reasoning_effort_options == ["low", "medium", "high", "xhigh"]
  end

  test "updates workflow codex command controls for future sessions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
    )

    assert {:ok, controls} =
             Controls.update(%{
               "model" => "gpt-5-mini",
               "reasoning_effort" => "low"
             })

    assert controls.model == "gpt-5-mini"
    assert controls.reasoning_effort == "low"

    assert Config.settings!().codex.command ==
             "codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5-mini\"' --config model_reasoning_effort=low app-server"

    assert {:ok, workflow} = Workflow.current()
    assert workflow.prompt == "You are an agent for this repository."
  end

  test "rejects invalid controls without changing workflow" do
    original_command = "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=high app-server"
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: original_command)

    assert {:error, {:invalid_controls, _message}} =
             Controls.update(%{"model" => "bad model", "reasoning_effort" => "turbo"})

    assert Config.settings!().codex.command == original_command
  end

  test "requires a single-line app-server command" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex agent")

    assert {:error, {:invalid_controls, "codex.command must contain app-server."}} =
             Controls.update(%{"reasoning_effort" => "low"})
  end
end
