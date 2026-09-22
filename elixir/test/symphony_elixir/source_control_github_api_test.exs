defmodule SymphonyElixir.SourceControlGitHubApiTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.SourceControl

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @tree String.duplicate("c", 40)

  @config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [
      %{context: "make-all", app_id: 15_368, subject: "head"}
    ]
  }

  test "read helpers surface github facts used by verification" do
    opts = [
      token: "token",
      request_fun: fn _token, path, _params, _opts -> {:ok, payload(path)} end
    ]

    assert {:ok, %{"id" => 1_368_436_395}} = SourceControl.fetch_repository(@config, opts)
    assert {:ok, @sha_a} = SourceControl.fetch_base_sha(@config, opts)
    assert {:ok, %{"commit" => _}} = SourceControl.fetch_commit(@config, @sha_b, opts)
    assert {:ok, [_pull | _]} = SourceControl.fetch_associated_pull_requests(@config, @sha_b, opts)
    assert {:ok, %{"number" => 15}} = SourceControl.fetch_pull_request(@config, 15, opts)
    assert {:ok, %{"status" => "ahead"}} = SourceControl.compare_commits(@config, @sha_a, @sha_b, opts)
    assert {:ok, runs} = SourceControl.fetch_check_runs(@config, @sha_b, opts)
    assert runs != []
    assert {:ok, _merge_commit} = SourceControl.fetch_merge_ref_commit(@config, 15, opts)
    assert {:ok, %{"sha" => _sha}} = SourceControl.fetch_git_commit(@config, @sha_a, opts)
  end

  test "http helper surfaces non-success github statuses" do
    opts = [
      token: "token",
      http_request: fn _url, _headers -> {:ok, %{status: 404, body: nil}} end
    ]

    assert {:error, {:github_status, 404}} = SourceControl.fetch_repository(@config, opts)
  end

  test "http helper surfaces transport failures" do
    opts = [
      token: "token",
      http_request: fn _url, _headers -> {:error, :timeout} end
    ]

    assert {:error, %SourceControl.Error{kind: :transport_failed}} =
             SourceControl.fetch_repository(@config, opts)
  end

  test "http helper does not follow redirects" do
    parent = self()

    opts = [
      token: "token",
      http_request: fn url, _headers ->
        send(parent, {:url, url})
        {:ok, %{status: 302, body: nil}}
      end
    ]

    assert {:error, {:github_status, 302}} = SourceControl.fetch_repository(@config, opts)
    assert_receive {:url, "https://api.github.com/repos/JCSchoeman96/symphony"}
    refute_receive {:url, _}
  end

  defp payload(path) do
    payload_handlers()
    |> Enum.find_value(fn {match?, response} -> if match?.(path), do: response.(), else: false end)
    |> case do
      nil -> %{}
      response -> response
    end
  end

  defp payload_handlers do
    [
      {&repository_payload?/1, &repository_payload/0},
      {&base_ref_payload?/1, &base_ref_payload/0},
      {&associated_pulls_payload?/1, &associated_pulls_payload/0},
      {&pull_request_payload?/1, &pull_request_payload/0},
      {&compare_payload?/1, &compare_payload/0},
      {&check_runs_payload?/1, &check_runs_payload/0},
      {&commit_payload?/1, &commit_payload/0},
      {&git_commit_payload?/1, &git_commit_payload/0}
    ]
  end

  defp repository_payload?(path), do: String.ends_with?(path, "/repos/JCSchoeman96/symphony")
  defp repository_payload, do: %{"id" => 1_368_436_395}

  defp base_ref_payload?(path), do: String.contains?(path, "/git/ref/heads/main")
  defp base_ref_payload, do: %{"object" => %{"sha" => @sha_a}}

  defp associated_pulls_payload?(path), do: String.contains?(path, "/commits/" <> @sha_b <> "/pulls")
  defp associated_pulls_payload, do: [open_pull()]

  defp pull_request_payload?(path), do: String.contains?(path, "/pulls/15")
  defp pull_request_payload, do: open_pull()

  defp compare_payload?(path), do: String.contains?(path, "/compare/")
  defp compare_payload, do: %{"status" => "ahead"}

  defp check_runs_payload?(path), do: String.contains?(path, "/check-runs")

  defp check_runs_payload do
    %{
      "total_count" => 1,
      "check_runs" => [
        %{
          "name" => "make-all",
          "head_sha" => @sha_b,
          "status" => "completed",
          "conclusion" => "success",
          "app" => %{"id" => 1}
        }
      ]
    }
  end

  defp commit_payload?(path), do: String.contains?(path, "/commits/" <> @sha_b)
  defp commit_payload, do: %{"commit" => %{"tree" => %{"sha" => @tree}}}

  defp git_commit_payload?(path), do: String.contains?(path, "/git/commits/" <> @sha_a)
  defp git_commit_payload, do: %{"sha" => @sha_a, "tree" => %{"sha" => @tree}}

  defp open_pull do
    %{
      "number" => 15,
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "merge_commit_sha" => @sha_a,
      "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => @sha_a, "ref" => "main"}
    }
  end
end
