defmodule Mix.Tasks.Governance.Check do
  use Mix.Task

  alias SymphonyElixir.Governance.Check

  @shortdoc "Validates the repository governance projection"
  @moduledoc """
  Runs the read-only governance consistency checker.

  Normal mode validates repository-local projection, status, immutable-blob,
  and skill-policy facts. Freeze mode requires one selector. `--candidate-phase`
  validates an active programme candidate, while `--materialize-decision`
  validates materialization of the exact accepted decision when no programme
  work is authorized. Both selectors use the same local Git candidate checks.
  """

  @switches [candidate_phase: :string, materialize_decision: :string, freeze: :boolean]

  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) when is_list(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("governance.check: invalid command-line options")
    end

    validate_cli_options!(opts)

    case Check.validate(repository_root(), opts) do
      :ok ->
        Mix.shell().info("governance.check: PASS")
        :ok

      {:error, diagnostics} ->
        Enum.each(diagnostics, fn diagnostic ->
          Mix.shell().error(format_diagnostic(diagnostic))
        end)

        Mix.raise("governance.check failed")
    end
  end

  defp validate_cli_options!(opts) do
    candidate_phase? = Keyword.has_key?(opts, :candidate_phase)
    materialize_decision? = Keyword.has_key?(opts, :materialize_decision)
    freeze? = Keyword.get(opts, :freeze) == true

    cond do
      candidate_phase? and materialize_decision? ->
        Mix.raise("governance.check: --candidate-phase and --materialize-decision are mutually exclusive")

      candidate_phase? and not freeze? ->
        Mix.raise("governance.check: --candidate-phase requires --freeze")

      materialize_decision? and not freeze? ->
        Mix.raise("governance.check: --materialize-decision requires --freeze")

      true ->
        :ok
    end
  end

  defp format_diagnostic(%{code: code, path: path, detail: detail}) do
    location = if is_binary(path), do: " [#{path}]", else: ""
    "governance.check: #{Atom.to_string(code)}#{location}: #{detail}"
  end

  defp repository_root do
    cwd = File.cwd!()

    if File.dir?(Path.join(cwd, "docs/symphony-hardening-playbook-v4.1")) do
      cwd
    else
      Path.expand("..", cwd)
    end
  end
end
