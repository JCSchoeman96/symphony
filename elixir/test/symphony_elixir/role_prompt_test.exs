defmodule SymphonyElixir.RolePromptReloadRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts) do
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, _issue, opts) do
    count = Process.get({__MODULE__, :turn_count}, 0) + 1
    Process.put({__MODULE__, :turn_count}, count)
    send(session.test_pid, {:role_prompt_turn, count, prompt})

    if count == 1 do
      File.write!(Keyword.fetch!(opts, :prompt_path), Keyword.fetch!(opts, :replacement_prompt))
    end

    {:ok, session}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.RolePromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}
  alias SymphonyElixir.Config.Schema

  test "routed prompts combine exactly one role policy with the workflow prompt" do
    workflow_prompt = "Workflow instructions for {{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{id: "planner-issue", identifier: "SYM-PROMPT", title: "Prompt", state: "Planning"}
    profiles = Profile.default_profiles("codex app-server", 20)
    assert {:ok, route} = Router.resolve(issue, profiles)

    prompt = PromptBuilder.build_prompt(issue, route: route)

    assert prompt =~ "Role policy: planner"
    assert prompt =~ "Workflow instructions for SYM-PROMPT"
    assert String.split(prompt, "Role policy:") |> length() == 2
    refute prompt =~ "Role policy: builder"
  end

  test "continuation prompts preserve the selected role policy" do
    profiles = Profile.default_profiles("codex app-server", 20)
    issue = %Issue{id: "review-issue", identifier: "SYM-REVIEW", title: "Review", state: "In Review"}
    assert {:ok, route} = Router.resolve(issue, profiles)

    prompt =
      AgentRunner.continuation_prompt_for_test(
        issue,
        route,
        2,
        3
      )

    assert prompt =~ "Role policy: reviewer"
    assert prompt =~ "Continuation guidance"
    refute prompt =~ "Role policy: fixer"
  end

  test "role prompt resolution handles optional, markdown, missing, and invalid names" do
    assert PromptBuilder.with_role_prompt("plain prompt", nil) == "plain prompt"
    assert PromptBuilder.role_prompt(nil) == nil

    issue = %Issue{id: "prompt-branches", identifier: "SYM-PROMPT-BRANCHES", state: "Planning"}
    assert {:ok, route} = Router.resolve(issue, Profile.default_profiles("codex app-server", 20))

    markdown_route = %{route | profile: %{route.profile | prompt: "planner.md"}}
    assert PromptBuilder.role_prompt(markdown_route) =~ "Role policy: planner"

    missing_route = %{route | profile: %{route.profile | prompt: "missing-role"}}
    assert PromptBuilder.role_prompt(missing_route) =~ "Role policy: planner"
    assert PromptBuilder.role_prompt(missing_route) =~ "missing-role"

    empty_route = %{route | profile: %{route.profile | prompt: ""}}
    assert PromptBuilder.role_prompt(empty_route) == nil

    invalid_name_route = %{route | profile: %{route.profile | prompt: 123}}
    assert PromptBuilder.role_prompt(invalid_name_route) == nil
    assert PromptBuilder.with_role_prompt("plain prompt", invalid_name_route) == "plain prompt"

    assert %Route{} = route
  end

  test "role prompt resolution can load a custom markdown file" do
    prompt_name = "runtime-custom-#{System.unique_integer([:positive])}.md"
    prompt_root = Path.expand("../../prompts", __DIR__)
    prompt_path = Path.join(prompt_root, prompt_name)
    prompt_body = "Role policy: runtime custom prompt"
    File.write!(prompt_path, prompt_body)

    on_exit(fn -> File.rm(prompt_path) end)

    issue = %Issue{id: "custom-prompt", identifier: "SYM-CUSTOM-PROMPT", state: "Planning"}
    assert {:ok, route} = Router.resolve(issue, Profile.default_profiles("codex app-server", 20))
    custom_route = %{route | profile: %{route.profile | prompt: prompt_name}}

    assert PromptBuilder.role_prompt(custom_route) == prompt_body
  end

  test "built-in role prompts reload from disk and fall back to the packaged copy" do
    prompt_root = Path.join(System.tmp_dir!(), "symphony-role-prompts-#{System.unique_integer([:positive])}")
    prompt_path = Path.join(prompt_root, "planner.md")
    File.mkdir_p!(prompt_root)
    File.write!(prompt_path, "Role policy: planner runtime version one")
    Application.put_env(:symphony_elixir, :role_prompt_root, prompt_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :role_prompt_root)
      File.rm_rf(prompt_root)
    end)

    issue = %Issue{id: "runtime-prompt", identifier: "SYM-RUNTIME-PROMPT", state: "Planning"}
    assert {:ok, route} = Router.resolve(issue, Profile.default_profiles("codex app-server", 20))
    assert PromptBuilder.role_prompt(route) == "Role policy: planner runtime version one"

    File.write!(prompt_path, "Role policy: planner runtime version two")
    assert PromptBuilder.role_prompt(route) == "Role policy: planner runtime version two"

    File.rm!(prompt_path)
    assert PromptBuilder.role_prompt(route) =~ "Role policy: planner"
  end

  test "an active attempt keeps its captured role prompt while future attempts reload" do
    test_pid = self()
    prompt_root = Path.join(System.tmp_dir!(), "symphony-role-prompt-attempt-#{System.unique_integer([:positive])}")
    prompt_path = Path.join(prompt_root, "builder.md")
    File.mkdir_p!(prompt_root)
    File.write!(prompt_path, "Role policy: builder attempt version one")
    Application.put_env(:symphony_elixir, :role_prompt_root, prompt_root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :role_prompt_root)
      File.rm_rf(prompt_root)
      Process.delete({SymphonyElixir.RolePromptReloadRuntime, :turn_count})
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "prompt-stability",
      identifier: "SYM-PROMPT-STABILITY",
      title: "Prompt stability",
      state: "Ready",
      dispatchable: true
    }

    assert {:ok, route} = Router.resolve(issue, Config.settings!().agent.profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.RolePromptReloadRuntime,
               test_pid: test_pid,
               prompt_path: prompt_path,
               replacement_prompt: "Role policy: builder attempt version two",
               route: route,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
             )

    assert_receive {:role_prompt_turn, 1, first_prompt}
    assert_receive {:role_prompt_turn, 2, second_prompt}
    assert first_prompt =~ "builder attempt version one"
    assert second_prompt =~ "builder attempt version one"
    refute second_prompt =~ "builder attempt version two"
    assert PromptBuilder.role_prompt(route) == "Role policy: builder attempt version two"
  end

  test "shipped role prompts state one bounded responsibility per role" do
    profiles = Profile.default_profiles("codex app-server", 20)

    for {state, role, required_text} <- [
          {"Planning", "planner", ["read-only", "Do not modify production source"]},
          {"Ready", "builder", ["workspace-write", "Do not self-review, approve, or merge"]},
          {"In Review", "reviewer", ["read-only", "PASS, FAIL, or BLOCKED"]},
          {"Changes Requested", "fixer", ["workspace-write", "Do not approve your own changes or merge"]}
        ] do
      issue = %Issue{id: "role-#{role}", identifier: "SYM-ROLE-#{role}", state: state}
      assert {:ok, route} = Router.resolve(issue, profiles)
      prompt = PromptBuilder.role_prompt(route)

      assert prompt =~ "Role policy: #{role}"
      Enum.each(required_text, &assert(prompt =~ &1))
    end
  end

  test "the shipped workflow remains legacy-compatible while Linear routed mode is gated" do
    workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)
    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(workflow_path)
    assert {:ok, settings} = Schema.parse(config)
    assert settings.agent.routing == "legacy"
    assert settings.agent.profiles == nil
    assert prompt =~ "role policy"
    refute prompt =~ "Merging"
    refute prompt =~ "Human Review"
    refute prompt =~ "full reset"
  end
end
