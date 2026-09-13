defmodule SymphonyElixir.RolePromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}

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
end
