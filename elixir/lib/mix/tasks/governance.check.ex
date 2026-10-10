defmodule Mix.Tasks.Governance.Check do
  use Mix.Task

  alias SymphonyElixir.Governance.Check

  @shortdoc "Validates the repository governance projection"
  @moduledoc """
  Runs the read-only governance consistency checker.

  Normal mode validates repository-local projection, status, immutable-blob,
  and skill-policy facts. Freeze mode also validates the local Git candidate
  against the accepted baseline recorded in the projection.
  """

  @switches [candidate_phase: :string, freeze: :boolean]

  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) when is_list(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("governance.check: invalid command-line options")
    end

    if Keyword.has_key?(opts, :candidate_phase) and Keyword.get(opts, :freeze) != true do
      Mix.raise("governance.check: --candidate-phase requires --freeze")
    end

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
