defmodule SymphonyElixir.GitHub.SourceControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef

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
    required_checks: [
      %{context: "make-all", app_id: 15_368, subject: "head"},
      %{context: "validate-pr-description", app_id: 15_368, subject: "head"}
    ]
  }

  test "duplicate successful checks with same identity are accepted" do
    candidate_ref = candidate_ref()

    assert :ok =
             SourceControl.verify_required_checks(
               @config,
               candidate_ref,
               @tree,
               request_opts(duplicate_success_checks())
             )
  end

  test "conflicting duplicate checks fail closed" do
    candidate_ref = candidate_ref()

    assert {:error, :ambiguous_check} =
             SourceControl.verify_required_checks(
               @config,
               candidate_ref,
               @tree,
               request_opts(conflicting_duplicate_checks())
             )
  end

  test "capture fails closed for ambiguous pull requests" do
    assert {:error, :ambiguous_pull_request} =
             SourceControl.capture_candidate_ref(
               @config,
               @sha_b,
               request_opts(fn path ->
                 if String.contains?(path, "/commits/" <> @sha_b <> "/pulls") do
                   [open_pull(15), open_pull(16)]
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "capture fails closed for fork pull requests" do
    assert {:error, :fork_pull_request} =
             SourceControl.capture_candidate_ref(
               @config,
               @sha_b,
               request_opts(fn path ->
                 if String.contains?(path, "/commits/" <> @sha_b <> "/pulls") do
                   [
                     %{
                       "number" => 15,
                       "state" => "open",
                       "head" => %{"sha" => @sha_b, "repo" => %{"id" => 999}},
                       "base" => %{"sha" => @sha_a, "ref" => "main"}
                     }
                   ]
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "verify candidate unchanged detects head movement" do
    candidate_ref = candidate_ref()

    assert {:error, :candidate_moved} =
             SourceControl.verify_candidate_unchanged(
               @config,
               candidate_ref,
               request_opts(fn path ->
                 if String.contains?(path, "/pulls/15") do
                   %{
                     "number" => 15,
                     "state" => "open",
                     "merged" => false,
                     "head" => %{"sha" => String.duplicate("f", 40), "repo" => %{"id" => 1_368_436_395}},
                     "base" => %{"sha" => @sha_a, "ref" => "main"}
                   }
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "missing required check fails closed" do
    candidate_ref = candidate_ref()

    assert {:error, :missing_required_check} =
             SourceControl.verify_required_checks(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 if String.contains?(path, "/check-runs") do
                   %{"total_count" => 0, "check_runs" => []}
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "verify merge accepts main advanced after a valid merge" do
    candidate_ref = candidate_ref()
    sha_m = String.duplicate("d", 40)
    sha_main = String.duplicate("e", 40)

    assert {:ok, %{merge_strategy: :ordinary}} =
             SourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 cond do
                   String.contains?(path, "/pulls/15") ->
                     %{"number" => 15, "merged" => true, "head" => %{"sha" => @sha_b}, "merge_commit_sha" => sha_m}

                   String.contains?(path, "/git/commits/" <> sha_m) ->
                     %{"sha" => sha_m, "tree" => %{"sha" => @tree}, "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]}

                   String.contains?(path, "/git/ref/heads/main") ->
                     %{"object" => %{"sha" => sha_main}}

                   String.contains?(path, "/compare/" <> sha_m <> "..." <> sha_main) ->
                     %{"status" => "behind"}

                   true ->
                     %{}
                 end
               end)
             )
  end

  test "verify merge fails when pull request is not merged" do
    candidate_ref = candidate_ref()

    assert {:error, :not_merged} =
             SourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 if String.contains?(path, "/pulls/15") do
                   %{"number" => 15, "merged" => false, "head" => %{"sha" => @sha_b}}
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "captures candidate ref from workspace head and github corroboration" do
    assert {:ok, ref, tree} =
             SourceControl.capture_candidate_ref(@config, @sha_b, request_opts(base_github_payload()))

    assert %CandidateRef{pr_identity: "15", candidate_sha: @sha_b} = ref
    assert tree == @tree
  end

  test "pending and failed checks fail closed" do
    candidate_ref = candidate_ref()

    assert {:error, :check_pending} =
             SourceControl.verify_required_checks(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 if String.contains?(path, "/check-runs") do
                   %{
                     "total_count" => 1,
                     "check_runs" => [Map.put(check_run("make-all", "success"), "status", "in_progress")]
                   }
                 else
                   base_github_payload().(path)
                 end
               end)
             )

    assert {:error, :check_not_successful} =
             SourceControl.verify_required_checks(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 if String.contains?(path, "/check-runs") do
                   %{
                     "total_count" => 1,
                     "check_runs" => [check_run("make-all", "failure")]
                   }
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "synthetic merge checks validate merge ref parents and tree" do
    config =
      Map.put(@config, :required_checks, [
        %{context: "make-all", app_id: 15_368, subject: "synthetic_merge"}
      ])

    candidate_ref = candidate_ref()
    sha_merge = String.duplicate("9", 40)

    assert :ok =
             SourceControl.verify_required_checks(
               config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 cond do
                   String.contains?(path, "/pulls/15/merge") ->
                     %{"sha" => sha_merge}

                   String.contains?(path, "/git/commits/" <> sha_merge) ->
                     %{
                       "sha" => sha_merge,
                       "tree" => %{"sha" => @tree},
                       "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
                     }

                   String.contains?(path, "/check-runs") ->
                     %{
                       "total_count" => 1,
                       "check_runs" => [
                         Map.merge(check_run("make-all", "success"), %{"head_sha" => sha_merge})
                       ]
                     }

                   true ->
                     base_github_payload().(path)
                 end
               end)
             )
  end

  test "capture fails for diverged ancestry and workspace head mismatch" do
    assert {:error, :candidate_not_based_on_base} =
             SourceControl.capture_candidate_ref(
               @config,
               @sha_b,
               request_opts(fn path ->
                 if String.contains?(path, "/compare/") do
                   %{"status" => "diverged"}
                 else
                   base_github_payload().(path)
                 end
               end)
             )

    assert {:error, :workspace_head_mismatch} =
             SourceControl.capture_candidate_ref(
               @config,
               @sha_b,
               request_opts(fn path ->
                 if String.contains?(path, "/pulls/15") do
                   %{
                     "number" => 15,
                     "state" => "open",
                     "merged" => false,
                     "head" => %{"sha" => String.duplicate("f", 40), "repo" => %{"id" => 1_368_436_395}},
                     "base" => %{"sha" => @sha_a, "ref" => "main"}
                   }
                 else
                   base_github_payload().(path)
                 end
               end)
             )
  end

  test "rejects unsupported check subjects and invalid synthetic merge refs" do
    candidate_ref = candidate_ref()

    assert {:error, :unsupported_check_subject} =
             SourceControl.verify_required_checks(
               Map.put(@config, :required_checks, [%{context: "make-all", app_id: 15_368, subject: "unknown"}]),
               candidate_ref,
               @tree,
               request_opts(base_github_payload())
             )

    assert {:error, :invalid_synthetic_merge_parents} =
             SourceControl.verify_required_checks(
               Map.put(@config, :required_checks, [
                 %{context: "make-all", app_id: 15_368, subject: "synthetic_merge"}
               ]),
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 cond do
                   String.contains?(path, "/pulls/15/merge") ->
                     %{"sha" => String.duplicate("9", 40)}

                   String.contains?(path, "/git/commits/") ->
                     %{
                       "sha" => String.duplicate("9", 40),
                       "tree" => %{"sha" => @tree},
                       "parents" => [%{"sha" => @sha_a}]
                     }

                   true ->
                     base_github_payload().(path)
                 end
               end)
             )
  end

  test "verify merge fails when squash parent does not match base" do
    candidate_ref = candidate_ref()

    assert {:error, :merge_parent_mismatch} =
             SourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 cond do
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
                       "parents" => [%{"sha" => String.duplicate("f", 40)}]
                     }

                   true ->
                     %{}
                 end
               end)
             )
  end

  test "verify merge fails when main does not contain merge commit" do
    candidate_ref = candidate_ref()
    sha_m = String.duplicate("d", 40)
    sha_main = String.duplicate("e", 40)

    assert {:error, :merge_not_on_main} =
             SourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(fn path ->
                 cond do
                   String.contains?(path, "/pulls/15") ->
                     %{"number" => 15, "merged" => true, "head" => %{"sha" => @sha_b}, "merge_commit_sha" => sha_m}

                   String.contains?(path, "/git/commits/" <> sha_m) ->
                     %{"sha" => sha_m, "tree" => %{"sha" => @tree}, "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]}

                   String.contains?(path, "/git/ref/heads/main") ->
                     %{"object" => %{"sha" => sha_main}}

                   String.contains?(path, "/compare/" <> sha_m <> "..." <> sha_main) ->
                     %{"status" => "ahead"}

                   true ->
                     %{}
                 end
               end)
             )
  end

  defp open_pull(number) do
    %{
      "number" => number,
      "state" => "open",
      "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => @sha_a, "ref" => "main"}
    }
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

  defp duplicate_success_checks do
    fn path ->
      if String.contains?(path, "/check-runs") do
        %{
          "total_count" => 3,
          "check_runs" => [
            check_run("make-all", "success"),
            check_run("validate-pr-description", "success"),
            check_run("validate-pr-description", "success")
          ]
        }
      else
        base_github_payload().(path)
      end
    end
  end

  defp conflicting_duplicate_checks do
    fn path ->
      if String.contains?(path, "/check-runs") do
        %{
          "total_count" => 3,
          "check_runs" => [
            check_run("make-all", "success"),
            check_run("validate-pr-description", "success"),
            check_run("validate-pr-description", "failure")
          ]
        }
      else
        base_github_payload().(path)
      end
    end
  end

  defp check_run(name, conclusion) do
    %{
      "name" => name,
      "head_sha" => @sha_b,
      "status" => "completed",
      "conclusion" => conclusion,
      "app" => %{"id" => 15_368}
    }
  end

  defp base_github_payload do
    fn path ->
      cond do
        String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
          %{"id" => 1_368_436_395}

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_a}}

        String.contains?(path, "/commits/" <> @sha_b <> "/pulls") ->
          [
            %{
              "number" => 15,
              "state" => "open",
              "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
              "base" => %{"sha" => @sha_a, "ref" => "main"}
            }
          ]

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "state" => "open",
            "merged" => false,
            "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
            "base" => %{"sha" => @sha_a, "ref" => "main"}
          }

        String.contains?(path, "/compare/" <> @sha_a <> "..." <> @sha_b) ->
          %{"status" => "ahead"}

        String.contains?(path, "/check-runs") ->
          %{
            "total_count" => 1,
            "check_runs" => [check_run("make-all", "success")]
          }

        String.contains?(path, "/commits/" <> @sha_b) ->
          %{"commit" => %{"tree" => %{"sha" => @tree}}}

        true ->
          %{}
      end
    end
  end
end
