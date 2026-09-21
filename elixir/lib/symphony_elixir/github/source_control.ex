defmodule SymphonyElixir.GitHub.SourceControl do
  @moduledoc """
  Bounded read-only GitHub source-control implementation.
  """

  require Logger

  alias SymphonyElixir.SourceControl.CandidateRef

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @user_agent "symphony"
  @max_check_runs_per_subject 300
  @max_associated_prs 100

  @type config :: %{
          kind: :github,
          repository: String.t(),
          repository_id: pos_integer(),
          base_branch: String.t(),
          token_env: String.t(),
          required_checks: [map()]
        }

  @spec secret_environment_names(config()) :: [String.t()]
  def secret_environment_names(%{token_env: token_env}) when is_binary(token_env) do
    [token_env]
  end

  def secret_environment_names(_config), do: []

  @spec fetch_repository(config(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_repository(config, opts \\ []) do
    {owner, repo} = split_repository(config.repository)
    get(config, "/repos/#{owner}/#{repo}", %{}, opts)
  end

  @spec fetch_base_sha(config(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_base_sha(config, opts \\ []) do
    {owner, repo} = split_repository(config.repository)

    case get(config, "/repos/#{owner}/#{repo}/git/ref/heads/#{config.base_branch}", %{}, opts) do
      {:ok, %{"object" => %{"sha" => sha}}} -> {:ok, normalize_sha(sha)}
      _ -> {:error, :base_ref_unavailable}
    end
  end

  @spec fetch_commit(config(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_commit(config, sha, opts \\ []) when is_binary(sha) do
    {owner, repo} = split_repository(config.repository)
    get(config, "/repos/#{owner}/#{repo}/commits/#{sha}", %{}, opts)
  end

  @spec fetch_associated_pull_requests(config(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_associated_pull_requests(config, sha, opts \\ []) when is_binary(sha) do
    {owner, repo} = split_repository(config.repository)
    fetch_associated_pulls_page(config, owner, repo, sha, 1, [], opts)
  end

  @spec fetch_pull_request(config(), String.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_pull_request(config, pr_number, opts \\ []) do
    {owner, repo} = split_repository(config.repository)
    get(config, "/repos/#{owner}/#{repo}/pulls/#{pr_number}", %{}, opts)
  end

  @spec compare_commits(config(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compare_commits(config, base_sha, head_sha, opts \\ [])
      when is_binary(base_sha) and is_binary(head_sha) do
    {owner, repo} = split_repository(config.repository)
    get(config, "/repos/#{owner}/#{repo}/compare/#{base_sha}...#{head_sha}", %{}, opts)
  end

  @spec fetch_check_runs(config(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_check_runs(config, head_sha, opts \\ []) when is_binary(head_sha) do
    {owner, repo} = split_repository(config.repository)
    fetch_check_runs_page(config, owner, repo, head_sha, 1, [], opts)
  end

  @spec fetch_merge_ref_commit(config(), String.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_merge_ref_commit(config, pr_number, opts \\ []) do
    with {:ok, pull} <- fetch_pull_request(config, pr_number, opts),
         :ok <- validate_pull_merge_eligibility(pull),
         merge_sha when is_binary(merge_sha) <- normalize_sha(pull["merge_commit_sha"]),
         {:ok, commit} <- fetch_git_commit(config, merge_sha, opts) do
      {:ok, commit}
    else
      nil -> {:error, :synthetic_merge_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_candidate_ref_binding(config(), CandidateRef.t()) :: :ok | {:error, term()}
  def validate_candidate_ref_binding(config, %CandidateRef{} = candidate_ref) do
    expected = CandidateRef.github_repository_identity(config.repository_id)

    if candidate_ref.repository_identity == expected do
      :ok
    else
      {:error, :repository_identity_mismatch}
    end
  end

  @spec fetch_git_commit(config(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_git_commit(config, sha, opts \\ []) when is_binary(sha) do
    {owner, repo} = split_repository(config.repository)
    get(config, "/repos/#{owner}/#{repo}/git/commits/#{sha}", %{}, opts)
  end

  @spec capture_candidate_ref(config(), String.t(), keyword()) ::
          {:ok, CandidateRef.t(), String.t()} | {:error, term()}
  def capture_candidate_ref(config, workspace_head_sha, opts \\ []) when is_binary(workspace_head_sha) do
    workspace_head_sha = normalize_sha(workspace_head_sha)

    with {:ok, repository} <- fetch_repository(config, opts),
         :ok <- validate_repository_id(repository, config.repository_id),
         {:ok, base_sha} <- fetch_base_sha(config, opts),
         {:ok, pulls} <- fetch_associated_pull_requests(config, workspace_head_sha, opts),
         {:ok, pull} <- select_eligible_pull(pulls, config),
         {:ok, fresh_pull} <- fetch_pull_request(config, pull["number"], opts),
         :ok <- validate_pull_request(fresh_pull, config, workspace_head_sha, base_sha),
         :ok <- validate_ancestry(config, base_sha, workspace_head_sha, opts),
         {:ok, commit} <- fetch_commit(config, workspace_head_sha, opts),
         candidate_tree_sha <- commit_tree_sha(commit),
         {:ok, candidate_ref} <-
           CandidateRef.new(%{
             repository_identity: CandidateRef.github_repository_identity(config.repository_id),
             base_sha: base_sha,
             candidate_sha: workspace_head_sha,
             pr_identity: Integer.to_string(fresh_pull["number"]),
             observed_pr_head_sha: normalize_sha(fresh_pull["head"]["sha"])
           }) do
      {:ok, candidate_ref, candidate_tree_sha}
    end
  end

  @spec verify_candidate_unchanged(config(), CandidateRef.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def verify_candidate_unchanged(config, %CandidateRef{} = candidate_ref, opts \\ []) do
    with :ok <- validate_candidate_ref_binding(config, candidate_ref),
         {:ok, repository} <- fetch_repository(config, opts),
         :ok <- validate_repository_id(repository, config.repository_id),
         {:ok, base_sha} <- fetch_base_sha(config, opts),
         true <- base_sha == candidate_ref.base_sha,
         {:ok, pull} <- fetch_pull_request(config, candidate_ref.pr_identity, opts),
         :ok <- validate_pull_identity(pull, candidate_ref, config),
         true <- normalize_sha(get_in(pull, ["head", "sha"])) == candidate_ref.candidate_sha,
         :ok <- validate_ancestry(config, base_sha, candidate_ref.candidate_sha, opts),
         {:ok, commit} <- fetch_commit(config, candidate_ref.candidate_sha, opts) do
      {:ok, commit_tree_sha(commit)}
    else
      false -> {:error, :candidate_moved}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify_required_checks(config(), CandidateRef.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def verify_required_checks(config, %CandidateRef{} = candidate_ref, candidate_tree_sha, opts \\ [])
      when is_binary(candidate_tree_sha) do
    checks = Map.get(config, :required_checks, [])

    if checks == [] do
      {:error, :required_checks_missing}
    else
      verify_required_checks_list(config, candidate_ref, candidate_tree_sha, checks, opts)
    end
  end

  defp verify_required_checks_list(config, candidate_ref, candidate_tree_sha, checks, opts) do
    with :ok <- validate_synthetic_merge_subjects(config, candidate_ref, candidate_tree_sha, checks, opts),
         {:ok, runs_by_lookup_sha} <- fetch_grouped_check_runs(config, candidate_ref, checks, opts) do
      evaluate_configured_checks(checks, runs_by_lookup_sha, candidate_ref)
    end
  end

  defp evaluate_configured_checks(checks, runs_by_lookup_sha, candidate_ref) do
    Enum.reduce_while(checks, :ok, fn check, _acc ->
      case evaluate_required_check(check, runs_by_lookup_sha, candidate_ref) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_synthetic_merge_subjects(config, candidate_ref, candidate_tree_sha, checks, opts) do
    if Enum.any?(checks, &synthetic_merge_check?/1) do
      do_validate_synthetic_merge_subject(config, candidate_ref, candidate_tree_sha, opts)
    else
      :ok
    end
  end

  defp do_validate_synthetic_merge_subject(config, candidate_ref, candidate_tree_sha, opts) do
    with {:ok, merge_commit} <- fetch_merge_ref_commit(config, candidate_ref.pr_identity, opts) do
      validate_synthetic_merge(merge_commit, candidate_ref, candidate_tree_sha)
    end
  end

  defp fetch_grouped_check_runs(config, candidate_ref, checks, opts) do
    lookup_shas =
      checks
      |> Enum.map(&check_run_lookup_sha(&1, candidate_ref))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(lookup_shas, %{}, fn lookup_sha, acc ->
      case fetch_check_runs(config, lookup_sha, opts) do
        {:ok, runs} -> {:cont, Map.put(acc, lookup_sha, runs)}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      runs_by_lookup_sha -> {:ok, runs_by_lookup_sha}
    end
  end

  defp evaluate_required_check(check, runs_by_lookup_sha, candidate_ref) do
    subject = normalize_subject(Map.get(check, :subject) || Map.get(check, "subject"))
    context = Map.get(check, :context) || Map.get(check, "context")
    app_id = Map.get(check, :app_id) || Map.get(check, "app_id")

    case check_run_lookup_sha(check, candidate_ref) do
      nil ->
        {:error, :unsupported_check_subject}

      lookup_sha ->
        runs = Map.get(runs_by_lookup_sha, lookup_sha, [])
        evaluate_check_runs(runs, context, app_id, lookup_sha, subject)
    end
  end

  defp synthetic_merge_check?(check) do
    normalize_subject(Map.get(check, :subject) || Map.get(check, "subject")) == :synthetic_merge
  end

  defp check_run_lookup_sha(check, candidate_ref) do
    case normalize_subject(Map.get(check, :subject) || Map.get(check, "subject")) do
      :head -> candidate_ref.candidate_sha
      :synthetic_merge -> candidate_ref.candidate_sha
      _ -> nil
    end
  end

  @spec verify_merge(config(), CandidateRef.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_merge(config, %CandidateRef{} = candidate_ref, candidate_tree_sha, opts \\ [])
      when is_binary(candidate_tree_sha) do
    with :ok <- validate_candidate_ref_binding(config, candidate_ref),
         {:ok, repository} <- fetch_repository(config, opts),
         :ok <- validate_repository_id(repository, config.repository_id),
         {:ok, pull} <- fetch_pull_request(config, candidate_ref.pr_identity, opts),
         true <- pull["merged"] == true,
         true <- normalize_sha(get_in(pull, ["head", "sha"])) == candidate_ref.candidate_sha,
         merge_sha when is_binary(merge_sha) <- normalize_sha(pull["merge_commit_sha"]),
         {:ok, merge_commit} <- fetch_git_commit(config, merge_sha, opts),
         {:ok, strategy} <- classify_merge_strategy(merge_commit, candidate_ref, candidate_tree_sha),
         {:ok, current_main_sha} <- fetch_base_sha(config, opts),
         :ok <- verify_main_contains_merge(config, merge_sha, current_main_sha, opts) do
      {:ok,
       %{
         merge_strategy: strategy,
         merge_sha: merge_sha,
         merge_tree_sha: Map.get(merge_commit, "tree", %{}) |> Map.get("sha"),
         current_main_sha: current_main_sha
       }}
    else
      false -> {:error, :not_merged}
      nil -> {:error, :missing_merge_sha}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_synthetic_merge(merge_commit, candidate_ref, candidate_tree_sha) do
    parents = Map.get(merge_commit, "parents", [])
    parent_shas = Enum.map(parents, fn parent -> normalize_sha(Map.get(parent, "sha")) end)
    merge_tree_sha = get_in(merge_commit, ["tree", "sha"]) |> normalize_sha()

    cond do
      parent_shas != [candidate_ref.base_sha, candidate_ref.candidate_sha] ->
        {:error, :invalid_synthetic_merge_parents}

      merge_tree_sha != normalize_sha(candidate_tree_sha) ->
        {:error, :invalid_synthetic_merge_tree}

      true ->
        :ok
    end
  end

  defp evaluate_check_runs(runs, context, app_id, lookup_sha, subject) do
    matching =
      Enum.filter(runs, fn run ->
        is_map(run) and
          check_run_matches_subject?(run, lookup_sha, subject) and
          check_run_field(run, "name") == context and
          app_id_for(run) == normalize_app_id(app_id)
      end)

    grouped =
      Enum.group_by(matching, fn run ->
        {check_run_field(run, "name"), app_id_for(run), check_run_field(run, "head_sha") |> normalize_sha()}
      end)

    case Map.get(grouped, {context, normalize_app_id(app_id), lookup_sha}, []) do
      [] ->
        {:error, :missing_required_check}

      observations ->
        evaluate_terminal_observations(observations)
    end
  end

  defp check_run_matches_subject?(run, lookup_sha, _subject) do
    check_run_field(run, "head_sha") |> normalize_sha() == lookup_sha
  end

  defp evaluate_terminal_observations(observations) do
    conclusions =
      Enum.map(observations, fn run ->
        if run["status"] == "completed", do: run["conclusion"], else: :pending
      end)

    cond do
      Enum.any?(conclusions, &(&1 == :pending)) ->
        {:error, :check_pending}

      Enum.all?(conclusions, &(&1 == "success")) ->
        :ok

      length(Enum.uniq(conclusions)) > 1 ->
        {:error, :ambiguous_check}

      true ->
        {:error, :check_not_successful}
    end
  end

  defp classify_merge_strategy(merge_commit, candidate_ref, candidate_tree_sha) do
    parents = Map.get(merge_commit, "parents", [])
    parent_shas = Enum.map(parents, fn parent -> normalize_sha(Map.get(parent, "sha")) end)
    merge_tree_sha = get_in(merge_commit, ["tree", "sha"]) |> normalize_sha()

    cond do
      parent_shas == [candidate_ref.base_sha, candidate_ref.candidate_sha] and
          merge_tree_sha == normalize_sha(candidate_tree_sha) ->
        {:ok, :ordinary}

      length(parent_shas) == 1 and parent_shas == [candidate_ref.base_sha] and
          merge_tree_sha == normalize_sha(candidate_tree_sha) ->
        {:ok, :squash}

      length(parent_shas) == 2 ->
        {:error, :unsupported_merge_strategy}

      length(parent_shas) == 1 ->
        {:error, :merge_parent_mismatch}

      true ->
        {:error, :unsupported_merge_strategy}
    end
  end

  defp verify_main_contains_merge(_config, merge_sha, current_main_sha, _opts) do
    if merge_sha == current_main_sha do
      :ok
    else
      {:error, :main_advanced_after_merge}
    end
  end

  defp select_eligible_pull(pulls, config) do
    open_on_base =
      Enum.filter(pulls, fn pull ->
        pull["state"] == "open" and
          normalize_sha(get_in(pull, ["base", "ref"])) == config.base_branch
      end)

    eligible = Enum.filter(open_on_base, &same_repository?(&1, config))

    case eligible do
      [pull] ->
        {:ok, pull}

      [] ->
        if open_on_base == [] do
          {:error, :no_eligible_pull_request}
        else
          {:error, :fork_pull_request}
        end

      _ ->
        {:error, :ambiguous_pull_request}
    end
  end

  defp validate_pull_request(pull, config, workspace_head_sha, base_sha) do
    with :ok <- validate_pull_merge_eligibility(pull) do
      cond do
        normalize_sha(get_in(pull, ["head", "sha"])) != workspace_head_sha ->
          {:error, :workspace_head_mismatch}

        normalize_sha(get_in(pull, ["base", "sha"])) != base_sha ->
          {:error, :base_sha_mismatch}

        normalize_sha(get_in(pull, ["base", "ref"])) != config.base_branch ->
          {:error, :base_branch_retargeted}

        not same_repository?(pull, config) ->
          {:error, :fork_pull_request}

        true ->
          :ok
      end
    end
  end

  defp validate_pull_identity(pull, candidate_ref, config) do
    with :ok <- validate_pull_merge_eligibility(pull) do
      cond do
        Integer.to_string(pull["number"]) != candidate_ref.pr_identity ->
          {:error, :pull_request_identity_mismatch}

        not same_repository?(pull, config) ->
          {:error, :repository_mismatch}

        normalize_sha(get_in(pull, ["base", "sha"])) != candidate_ref.base_sha ->
          {:error, :base_sha_mismatch}

        normalize_sha(get_in(pull, ["base", "ref"])) != config.base_branch ->
          {:error, :base_branch_retargeted}

        true ->
          :ok
      end
    end
  end

  defp validate_pull_merge_eligibility(pull) do
    cond do
      pull["merged"] == true ->
        {:error, :pull_request_already_merged}

      pull["state"] != "open" ->
        {:error, :pull_request_not_open}

      pull["draft"] == true ->
        {:error, :pull_request_draft}

      pull["mergeable"] == false ->
        {:error, :pull_request_not_mergeable}

      pull["mergeable"] == nil ->
        {:error, :pull_request_mergeability_pending}

      true ->
        :ok
    end
  end

  defp fetch_associated_pulls_page(config, owner, repo, sha, page, acc, opts) do
    with {:ok, pulls} <-
           get(
             config,
             "/repos/#{owner}/#{repo}/commits/#{sha}/pulls",
             %{"per_page" => 100, "page" => page},
             opts
           ) do
      pulls = if is_list(pulls), do: pulls, else: []
      acc = acc ++ pulls

      cond do
        length(acc) > @max_associated_prs ->
          {:error, :too_many_associated_pull_requests}

        pulls == [] ->
          {:ok, acc}

        length(pulls) < 100 ->
          {:ok, acc}

        true ->
          fetch_associated_pulls_page(config, owner, repo, sha, page + 1, acc, opts)
      end
    end
  end

  defp validate_ancestry(config, base_sha, head_sha, opts) do
    case compare_commits(config, base_sha, head_sha, opts) do
      {:ok, %{"status" => status}} when status in ["ahead", "identical"] -> :ok
      {:ok, %{"status" => "diverged"}} -> {:error, :candidate_not_based_on_base}
      _ -> {:error, :ancestry_unavailable}
    end
  end

  defp same_repository?(pull, config) do
    get_in(pull, ["head", "repo", "id"]) == config.repository_id
  end

  defp validate_repository_id(%{"id" => id}, expected_id) do
    if id == expected_id, do: :ok, else: {:error, :repository_id_mismatch}
  end

  defp validate_repository_id(_repository, _expected_id), do: {:error, :repository_unavailable}

  defp fetch_check_runs_page(config, owner, repo, head_sha, page, acc, opts) do
    with {:ok, %{"check_runs" => runs, "total_count" => total}} <-
           get(config, "/repos/#{owner}/#{repo}/commits/#{head_sha}/check-runs", %{"per_page" => 100, "page" => page}, opts) do
      continue_check_runs_page(%{
        config: config,
        owner: owner,
        repo: repo,
        head_sha: head_sha,
        page: page,
        acc: acc,
        runs: runs,
        total: total,
        opts: opts
      })
    end
  end

  defp continue_check_runs_page(%{page: page, acc: acc, runs: runs, total: total} = state) do
    runs = if is_list(runs), do: runs, else: []
    acc = acc ++ runs

    cond do
      length(acc) > @max_check_runs_per_subject or (acc == [] and page > 1) ->
        {:error, :too_many_check_runs}

      length(acc) >= total or runs == [] ->
        {:ok, acc}

      true ->
        fetch_check_runs_page(
          state.config,
          state.owner,
          state.repo,
          state.head_sha,
          page + 1,
          acc,
          state.opts
        )
    end
  end

  defp get(config, path, params, opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_get/4)
    token = resolve_token(config, opts)

    if is_binary(token) and token != "" do
      request_fun.(token, path, params, opts)
    else
      {:error, :missing_source_control_token}
    end
  end

  defp perform_get(token, path, params, opts) do
    api_url = Keyword.get(opts, :api_url, @default_api_url)
    query = URI.encode_query(params)
    url = api_url <> path <> if(query == "", do: "", else: "?" <> query)

    headers = [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer " <> token},
      {"user-agent", @user_agent},
      {"x-github-api-version", @api_version}
    ]

    request_impl = Keyword.get(opts, :http_request, &default_http_request/2)

    case request_impl.(url, headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_http_request(url, headers) do
    case Req.request(method: :get, url: url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body}}

      {:ok, %{status: status}} ->
        {:ok, %{status: status, body: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_token(config, opts) do
    Keyword.get_lazy(opts, :token, fn ->
      env_name = Map.get(config, :token_env, "GITHUB_TOKEN")
      System.get_env(env_name)
    end)
  end

  defp split_repository(repository) when is_binary(repository) do
    case String.split(repository, "/", parts: 2) do
      [owner, repo] -> {owner, repo}
      _ -> {"", ""}
    end
  end

  defp commit_tree_sha(commit) do
    get_in(commit, ["commit", "tree", "sha"]) || get_in(commit, ["tree", "sha"])
  end

  defp normalize_sha(nil), do: nil

  defp normalize_sha(value) when is_binary(value) do
    trimmed = String.downcase(String.trim(value))
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_subject("head"), do: :head
  defp normalize_subject(:head), do: :head
  defp normalize_subject("synthetic_merge"), do: :synthetic_merge
  defp normalize_subject(:synthetic_merge), do: :synthetic_merge
  defp normalize_subject(_), do: :invalid

  defp normalize_app_id(value) when is_integer(value), do: value

  defp normalize_app_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp normalize_app_id(value), do: value

  defp app_id_for(%{"app" => %{"id" => id}}), do: id
  defp app_id_for(%{"app" => nil}), do: nil
  defp app_id_for(_run), do: nil

  defp check_run_field(run, key) when is_map(run), do: Map.get(run, key) || Map.get(run, String.to_atom(key))
end
