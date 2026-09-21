defmodule SymphonyElixir.SourceControl.MergeVerificationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.SourceControl, as: GitHubSourceControl
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.SourceControl.MergeVerification

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @sha_m String.duplicate("d", 40)
  @tree String.duplicate("c", 40)

  @config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: []
  }

  test "verifies accepted ordinary two-parent merge form" do
    candidate_ref = candidate_ref()

    assert {:ok, %{merge_strategy: :ordinary}} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(ordinary_merge_payload())
             )
  end

  test "verifies accepted squash one-parent merge form" do
    candidate_ref = candidate_ref()

    assert {:ok, %{merge_strategy: :squash}} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(squash_merge_payload())
             )
  end

  test "fails closed on unsupported rebase-style merge" do
    candidate_ref = candidate_ref()

    assert {:error, :unsupported_merge_strategy} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(rebase_merge_payload())
             )
  end

  test "host verify_merge_from_evidence reports not merged pull requests" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok,
                  cond do
                    repository_payload(path) ->
                      repository_payload(path)

                    String.contains?(path, "/pulls/15") ->
                      %{"number" => 15, "merged" => false, "head" => %{"sha" => @sha_b}}

                    true ->
                      %{}
                  end}
               end
             )

    assert verification.status == :not_merged
  end

  test "host verify_merge_from_evidence rejects stale policy fingerprint" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: "sha256:deadbeef"
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}}
             )

    refute MergeVerification.verified?(verification)
  end

  defp candidate_ref do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    ref
  end

  defp request_opts(payload_fun) do
    [
      token: "token",
      request_fun: fn _token, path, _params, _opts ->
        {:ok, payload_fun.(path)}
      end
    ]
  end

  defp repository_payload(path) do
    if String.ends_with?(path, "/repos/JCSchoeman96/symphony"),
      do: %{"id" => 1_368_436_395},
      else: nil
  end

  defp ordinary_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end

  defp squash_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end

  defp rebase_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}, %{"sha" => String.duplicate("e", 40)}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end
end
