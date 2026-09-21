defmodule SymphonyElixir.SourceControl do
  @moduledoc """
  Provider-neutral source-control authority seam for H-050C.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.SourceControl, as: GitHubSourceControl

  alias SymphonyElixir.SourceControl.{
    CandidateRef,
    CandidateVerification,
    MergeVerification,
    RepositoryProbe
  }

  alias SymphonyElixir.WorkControl.{SemanticTransitionIntent, WorkflowLifecycle}

  @capabilities [
    :repository_identity_read,
    :pull_request_read,
    :commit_read,
    :check_runs_read,
    :merge_observation
  ]

  @capture_transitions [{:in_progress, :in_review}, {:changes_requested, :in_review}]
  @review_acceptance_transition {:in_review, :ready_to_merge}

  @spec capabilities() :: [atom()]
  def capabilities, do: @capabilities

  @spec configured?() :: boolean()
  def configured? do
    case settings_config() do
      {:ok, _config} -> true
      _ -> false
    end
  end

  @spec policy_fingerprint() :: String.t() | nil
  def policy_fingerprint do
    with {:ok, config} <- settings_config(),
         {:ok, settings} <- Config.settings() do
      policy_fingerprint_for(config, settings)
    else
      _ -> nil
    end
  end

  @spec policy_fingerprint_for(map(), map()) :: String.t()
  def policy_fingerprint_for(config, settings) when is_map(config) and is_map(settings) do
    project_id = symphony_project_id(settings)

    canonical_checks =
      Enum.map(config.required_checks || [], fn check ->
        %{
          context: Map.get(check, :context) || Map.get(check, "context"),
          app_id: Map.get(check, :app_id) || Map.get(check, "app_id"),
          subject: Map.get(check, :subject) || Map.get(check, "subject")
        }
      end)

    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary([
          project_id,
          config.kind,
          config.repository,
          config.repository_id,
          config.base_branch,
          canonical_checks
        ])
      )

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  @spec secret_environment_names() :: [String.t()]
  def secret_environment_names do
    case settings_config() do
      {:ok, config} -> GitHubSourceControl.secret_environment_names(config)
      _ -> []
    end
  end

  @spec reconcile_stored_evidence(WorkflowLifecycle.state() | atom(), term(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def reconcile_stored_evidence(state, evidence, opts \\ []) do
    evidence = normalize_evidence(evidence)

    case state do
      :ready_to_merge ->
        reconcile_ready_to_merge_evidence(evidence, opts)

      _ ->
        {:ok, evidence}
    end
  end

  @spec enrich_guard_evidence(SemanticTransitionIntent.t(), map(), term()) ::
          {:ok, [map()]} | {:error, term()}
  def enrich_guard_evidence(%SemanticTransitionIntent{} = intent, context, evidence) do
    evidence = normalize_evidence(evidence)
    transition = {intent.requested_from, intent.requested_to}

    cond do
      transition in @capture_transitions ->
        enrich_candidate_capture(intent, context, evidence)

      transition == @review_acceptance_transition ->
        enrich_review_acceptance(intent, context, evidence)

      true ->
        {:ok, evidence}
    end
  end

  @spec verify_merge_from_evidence(term(), keyword()) ::
          {:ok, MergeVerification.t()} | {:error, term()}
  def verify_merge_from_evidence(evidence, opts \\ []) do
    with {:ok, config} <- settings_config(opts),
         {:ok, candidate_evidence} <- extract_review_acceptance_evidence(evidence),
         {:ok, candidate_ref} <- decode_candidate_ref(candidate_evidence),
         :ok <- validate_policy_fingerprint(candidate_evidence, config, opts),
         candidate_tree_sha <- Map.get(candidate_evidence, :candidate_tree_sha),
         {:ok, merge_facts} <-
           GitHubSourceControl.verify_merge(config, candidate_ref, candidate_tree_sha, opts) do
      {:ok,
       MergeVerification.new(%{
         status: :verified,
         candidate_ref: candidate_ref,
         merge_strategy: merge_facts.merge_strategy,
         merge_sha: merge_facts.merge_sha,
         merge_tree_sha: merge_facts.merge_tree_sha,
         current_main_sha: merge_facts.current_main_sha,
         main_contains_merge?: true
       })}
    else
      {:error, :not_merged} ->
        {:ok, merge_verification_error(:not_merged, evidence)}

      {:error, reason} ->
        {:ok, merge_verification_error(reason, evidence)}
    end
  end

  @spec extract_candidate_ref(term()) :: {:ok, CandidateRef.t()} | {:error, term()}
  def extract_candidate_ref(evidence) do
    case find_evidence(evidence, :candidate_state_verified) do
      {:ok, entry} -> decode_candidate_ref(entry)
      error -> error
    end
  end

  @spec read_current_candidate_status(map(), keyword()) :: map()
  def read_current_candidate_status(host_context, opts \\ []) when is_map(host_context) do
    evidence = Map.get(host_context, :guard_evidence, [])

    with {:ok, config} <- settings_config(opts),
         {:ok, candidate_evidence} <- find_candidate_state_evidence(evidence),
         {:ok, candidate_ref} <- decode_candidate_ref(candidate_evidence),
         {:ok, candidate_tree_sha} <-
           GitHubSourceControl.verify_candidate_unchanged(config, candidate_ref, opts),
         :ok <- GitHubSourceControl.verify_required_checks(config, candidate_ref, candidate_tree_sha, opts) do
      %{
        repository: config.repository,
        pr_number: candidate_ref.pr_identity,
        base_sha: candidate_ref.base_sha,
        candidate_sha: candidate_ref.candidate_sha,
        candidate_tree_sha: candidate_tree_sha,
        candidate_unchanged?: true,
        verification_state: "verified"
      }
    else
      {:error, :candidate_moved} ->
        stale_candidate_status(evidence, "moved")

      {:error, reason} ->
        %{
          verification_state: "not_ready",
          reason: sanitize_reason(reason)
        }
    end
  end

  defp enrich_candidate_capture(_intent, context, evidence) do
    case settings_config(github_opts(context)) do
      {:error, reason} ->
        {:error, {:source_control, reason}}

      {:ok, config} ->
        with {:ok, repository_context} <- repository_context(context),
             {:ok, probe} <- RepositoryProbe.probe(repository_context, probe_opts(context)),
             true <- probe.clean? || {:error, :dirty_workspace},
             head_sha when is_binary(head_sha) <- probe.head_sha || {:error, :missing_workspace_head},
             {:ok, candidate_ref, candidate_tree_sha} <-
               GitHubSourceControl.capture_candidate_ref(config, head_sha, github_opts(context)),
             {:ok, settings} <- Config.settings() do
          {:ok,
           evidence ++
             [
               candidate_state_evidence(
                 :verified,
                 candidate_ref,
                 candidate_tree_sha,
                 policy_fingerprint_for(config, settings)
               )
             ]}
        else
          {:error, reason} -> {:error, {:source_control, reason}}
          false -> {:error, {:source_control, :dirty_workspace}}
        end
    end
  end

  defp enrich_review_acceptance(intent, context, evidence) do
    case settings_config(github_opts(context)) do
      {:error, reason} ->
        {:error, {:source_control, reason}}

      {:ok, config} ->
        with {:ok, candidate_evidence} <- find_candidate_state_evidence(context_evidence(context, intent)),
             {:ok, candidate_ref} <- decode_candidate_ref(candidate_evidence),
             :ok <- GitHubSourceControl.validate_candidate_ref_binding(config, candidate_ref),
             {:ok, settings} <- Config.settings(),
             :ok <- validate_policy_fingerprint(candidate_evidence, config, settings),
             {:ok, candidate_tree_sha} <-
               GitHubSourceControl.verify_candidate_unchanged(config, candidate_ref, github_opts(context)),
             :ok <-
               GitHubSourceControl.verify_required_checks(
                 config,
                 candidate_ref,
                 candidate_tree_sha,
                 github_opts(context)
               ) do
          fingerprint = policy_fingerprint_for(config, settings)

          {:ok,
           evidence ++
             [
               review_acceptance_evidence(
                 :verified,
                 candidate_ref,
                 candidate_tree_sha,
                 fingerprint,
                 CandidateVerification.new(%{
                   status: :verified,
                   candidate_ref: candidate_ref,
                   candidate_tree_sha: candidate_tree_sha,
                   policy_fingerprint: fingerprint
                 })
               )
             ]}
        else
          {:error, reason} -> {:error, {:source_control, reason}}
        end
    end
  end

  defp candidate_state_evidence(outcome, candidate_ref, candidate_tree_sha, policy_fingerprint) do
    %{
      class: :mechanical_guard,
      name: :candidate_state_verified,
      outcome: outcome,
      candidate_ref: encode_candidate_ref(candidate_ref),
      candidate_tree_sha: candidate_tree_sha,
      policy_fingerprint: policy_fingerprint
    }
  end

  defp review_acceptance_evidence(outcome, candidate_ref, candidate_tree_sha, policy_fingerprint, verification) do
    %{
      class: :mechanical_guard,
      name: :review_acceptance_verified,
      outcome: outcome,
      candidate_ref: encode_candidate_ref(candidate_ref),
      candidate_tree_sha: candidate_tree_sha,
      policy_fingerprint: policy_fingerprint,
      verification: verification
    }
  end

  defp reconcile_ready_to_merge_evidence(evidence, opts) do
    case settings_config(opts) do
      {:error, :unconfigured} ->
        {:ok, invalidate_source_control_evidence(evidence, :unconfigured)}

      {:ok, config} ->
        {:ok, reconcile_configured_ready_to_merge(evidence, config, opts)}
    end
  end

  defp reconcile_configured_ready_to_merge(evidence, config, opts) do
    case extract_review_acceptance_evidence(evidence) do
      {:ok, entry} ->
        reconcile_verified_review_acceptance(evidence, entry, config, opts)

      {:error, _} ->
        reconcile_missing_review_acceptance(evidence)
    end
  end

  defp reconcile_verified_review_acceptance(evidence, entry, config, opts) do
    case verify_review_acceptance_freshness(entry, config, opts) do
      :ok -> evidence
      {:stale, reason} -> invalidate_review_acceptance(evidence, reason)
    end
  end

  defp reconcile_missing_review_acceptance(evidence) do
    if Enum.any?(evidence, &match?(%{name: :review_acceptance_verified}, &1)) do
      invalidate_review_acceptance(evidence, :review_acceptance_missing)
    else
      evidence
    end
  end

  defp verify_review_acceptance_freshness(entry, config, opts) do
    with {:ok, candidate_ref} <- decode_candidate_ref(entry),
         :ok <- GitHubSourceControl.validate_candidate_ref_binding(config, candidate_ref),
         :ok <- validate_policy_fingerprint(entry, config, settings_from_opts(opts)),
         candidate_tree_sha when is_binary(candidate_tree_sha) <- Map.get(entry, :candidate_tree_sha),
         {:ok, _} <- GitHubSourceControl.verify_candidate_unchanged(config, candidate_ref, opts),
         :ok <-
           GitHubSourceControl.verify_required_checks(config, candidate_ref, candidate_tree_sha, opts) do
      :ok
    else
      {:error, :policy_fingerprint_mismatch} -> {:stale, :policy_fingerprint_mismatch}
      {:error, :repository_identity_mismatch} -> {:stale, :repository_identity_mismatch}
      _ -> {:stale, :candidate_moved}
    end
  end

  defp invalidate_source_control_evidence(evidence, reason) do
    Enum.map(evidence, fn
      %{name: name} = entry when name in [:candidate_state_verified, :review_acceptance_verified] ->
        Map.put(entry, :outcome, :stale)
        |> Map.put(:stale_reason, reason)

      entry ->
        entry
    end)
  end

  defp invalidate_review_acceptance(evidence, reason) do
    Enum.map(evidence, fn
      %{name: :review_acceptance_verified} = entry ->
        Map.put(entry, :outcome, :stale)
        |> Map.put(:stale_reason, reason)

      entry ->
        entry
    end)
  end

  defp find_candidate_state_evidence(evidence) do
    case find_evidence(evidence, :candidate_state_verified) do
      {:ok, %{outcome: :verified} = entry} -> {:ok, entry}
      {:ok, _} -> {:error, :candidate_state_missing}
      {:error, :evidence_not_found} -> {:error, :candidate_state_missing}
    end
  end

  defp extract_review_acceptance_evidence(evidence) do
    case find_evidence(evidence, :review_acceptance_verified) do
      {:ok, %{outcome: :verified} = entry} -> {:ok, entry}
      {:ok, _} -> {:error, :review_acceptance_missing}
      error -> error
    end
  end

  defp find_evidence(evidence, name) do
    case Enum.find(normalize_evidence(evidence), &match?(%{class: :mechanical_guard, name: ^name}, &1)) do
      %{class: :mechanical_guard, name: ^name} = entry -> {:ok, entry}
      _ -> {:error, :evidence_not_found}
    end
  end

  defp decode_candidate_ref(%{candidate_ref: candidate_ref}) do
    case candidate_ref do
      %CandidateRef{} = ref ->
        CandidateRef.validate(ref)

      map when is_map(map) ->
        CandidateRef.new(map)

      _ ->
        {:error, :malformed_candidate_ref}
    end
  end

  defp decode_candidate_ref(_), do: {:error, :malformed_candidate_ref}

  defp encode_candidate_ref(%CandidateRef{} = ref), do: Map.from_struct(ref)

  defp validate_policy_fingerprint(evidence, config, settings_or_opts) do
    settings =
      cond do
        is_list(settings_or_opts) -> settings_from_opts(settings_or_opts)
        is_map(settings_or_opts) -> settings_or_opts
        true -> Config.settings!()
      end

    expected = policy_fingerprint_for(config, settings)

    if Map.get(evidence, :policy_fingerprint) == expected do
      :ok
    else
      {:error, :policy_fingerprint_mismatch}
    end
  end

  defp merge_verification_error(reason, evidence) do
    candidate_ref =
      case extract_review_acceptance_evidence(evidence) do
        {:ok, entry} ->
          case decode_candidate_ref(entry) do
            {:ok, ref} -> ref
            _ -> nil
          end

        _ ->
          nil
      end

    MergeVerification.new(%{
      status: error_status(reason),
      reason: reason,
      candidate_ref: candidate_ref || blank_candidate_ref()
    })
  end

  defp blank_candidate_ref do
    %CandidateRef{
      repository_identity: "github:repository:0",
      base_sha: String.duplicate("0", 40),
      candidate_sha: String.duplicate("0", 40),
      pr_identity: "0",
      observed_pr_head_sha: String.duplicate("0", 40)
    }
  end

  defp error_status(:not_merged), do: :not_merged
  defp error_status(:unsupported_merge_strategy), do: :unsupported_strategy
  defp error_status(:ambiguous_pull_request), do: :ambiguous
  defp error_status(:main_advanced_after_merge), do: :main_moved
  defp error_status(_reason), do: :mismatch

  defp stale_candidate_status(evidence, state) do
    case find_candidate_state_evidence(evidence) do
      {:ok, entry} ->
        %{
          repository: get_in(entry, [:candidate_ref, :repository_identity]),
          pr_number: get_in(entry, [:candidate_ref, :pr_identity]),
          base_sha: get_in(entry, [:candidate_ref, :base_sha]),
          candidate_sha: get_in(entry, [:candidate_ref, :candidate_sha]),
          candidate_tree_sha: Map.get(entry, :candidate_tree_sha),
          candidate_unchanged?: false,
          verification_state: state
        }

      _ ->
        %{verification_state: state}
    end
  end

  defp repository_context(context) do
    case Map.get(context, :repository_context) || Map.take(context, [:workspace_path, :worker_host]) do
      %{workspace_path: path} = repo_context when is_binary(path) and path != "" ->
        {:ok, repo_context}

      _ ->
        {:error, :repository_context_unavailable}
    end
  end

  defp context_evidence(context, intent) do
    case Map.get(context, :guard_evidence) do
      evidence when is_list(evidence) and evidence != [] -> evidence
      _ -> intent.guard_evidence
    end
  end

  defp settings_config(opts \\ []) do
    case Keyword.get(opts, :source_control_config) do
      config when is_map(config) ->
        validate_source_control_config(normalize_config(config))

      _ ->
        with {:ok, settings} <- Config.settings(),
             %{source_control: %{kind: kind} = source_control} when not is_nil(kind) <- settings do
          validate_source_control_config(normalize_config(source_control))
        else
          _ -> {:error, :unconfigured}
        end
    end
  end

  defp validate_source_control_config(config) when is_map(config) do
    case Map.get(config, :required_checks, []) do
      checks when is_list(checks) and checks != [] -> {:ok, config}
      _ -> {:error, :required_checks_missing}
    end
  end

  defp settings_from_opts(opts) do
    case Keyword.get(opts, :settings) do
      settings when is_map(settings) -> settings
      _ -> Config.settings!()
    end
  end

  defp normalize_config(%{kind: "github"} = config) do
    %{
      kind: :github,
      repository: config.repository,
      repository_id: config.repository_id,
      base_branch: config.base_branch,
      token_env: config.token_env,
      required_checks: normalize_required_checks(config.required_checks)
    }
  end

  defp normalize_config(%{kind: :github} = config) do
    %{config | required_checks: normalize_required_checks(config.required_checks)}
  end

  defp normalize_required_checks(nil), do: []

  defp normalize_required_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      %{
        context: Map.get(check, :context) || Map.get(check, "context"),
        app_id: Map.get(check, :app_id) || Map.get(check, "app_id"),
        subject: Map.get(check, :subject) || Map.get(check, "subject")
      }
    end)
  end

  defp normalize_evidence(evidence) when is_list(evidence), do: evidence
  defp normalize_evidence(evidence) when is_map(evidence), do: [evidence]
  defp normalize_evidence(_), do: []

  defp probe_opts(context) do
    Keyword.take(Map.get(context, :probe_opts, []), [:command_runner, :remote_command_runner])
  end

  defp github_opts(context) do
    Map.get(context, :github_opts, [])
  end

  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason(reason) when is_binary(reason), do: reason
  defp sanitize_reason(_reason), do: "unavailable"

  defp symphony_project_id(%{symphony: %{project_id: project_id}}), do: project_id
  defp symphony_project_id(_settings), do: nil
end
