defmodule RunicAI.Coding.RLM.ExecutionEvidence do
  @moduledoc """
  Normalizes project-execution evidence for mutating coding workflows.

  Source inspection and semantic review are useful, but they cannot prove that
  generated code parses, compiles, or passes its project checks. This module
  turns the latest observed formatter/compiler/test/runtime command results into
  one required acceptance result without assuming a language or build tool.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck

  @execution_tools ~w(
    compile_project project_command run_formatter run_linter
    run_tests runtime_smoke
  )

  @verification_subcommands %{
    "mix" => ~w(compile test format dialyzer credo run),
    "cargo" => ~w(check test fmt clippy run build),
    "go" => ~w(test vet build run),
    "npm" => ~w(test run build),
    "pnpm" => ~w(test run build),
    "yarn" => ~w(test run build),
    "bun" => ~w(test run build),
    "make" => ~w(test check lint build)
  }

  @verification_executables ~w(pytest ruff mypy eslint tsc)

  @spec result(map(), keyword()) :: AcceptanceCheck.result()
  def result(context, opts \\ []) when is_map(context) and is_list(opts) do
    check =
      AcceptanceCheck.new!(:command_passes,
        id: Keyword.get(opts, :id, "implementation-execution-verification"),
        params: %{command: ["project-native-verification"]},
        metadata: %{source: __MODULE__}
      )

    observations = current_observations(context)
    failures = Enum.filter(observations, &(observation_status(&1) == :fail))
    passes = Enum.filter(observations, &(observation_status(&1) == :pass))

    cond do
      failures != [] ->
        AcceptanceCheck.result(
          check,
          :fail,
          "the latest project execution evidence contains failures",
          evidence_metadata(observations, failures)
        )

      passes != [] ->
        AcceptanceCheck.result(
          check,
          :pass,
          "project-native execution verification passed",
          evidence_metadata(observations, [])
        )

      true ->
        AcceptanceCheck.result(
          check,
          :fail,
          "mutating implementation completed without executable verification evidence",
          %{
            observed: [],
            repair_instruction:
              "Run the project-native formatter, compiler, tests, linter, or runtime smoke and repair failures before claiming completion."
          }
        )
    end
  end

  @doc false
  @spec verification_observation?(map() | struct()) :: boolean()
  def verification_observation?(observation) do
    tool = field(observation, :tool) |> to_string_or_nil()

    tool in @execution_tools or verification_argv?(field(observation, :argv)) or
      verification_command?(field(observation, :command))
  end

  defp current_observations(context) do
    context
    |> observations()
    |> Enum.filter(&verification_observation?/1)
    |> Enum.reduce(%{}, fn observation, current ->
      Map.put(current, observation_key(observation), observation)
    end)
    |> Map.values()
  end

  defp observations(context) do
    direct =
      []
      |> Kernel.++(list_field(context, :command_results))
      |> Kernel.++(list_field(context, :verifications))
      |> Kernel.++(list_field(context, :runtime_smokes))

    child =
      context
      |> list_field(:child_results)
      |> Enum.flat_map(&list_field(&1, :command_statuses))

    # Repair-loop command results are deterministic reruns made after child
    # work. Put them last so they supersede the verifier child's earlier result
    # for the same argv while still requiring the latest rerun to pass.
    child ++ direct
  end

  defp observation_key(observation) do
    command =
      field(observation, :argv) || field(observation, :command) || field(observation, :tool)

    case command do
      argv when is_list(argv) -> inspect(argv)
      command when is_binary(command) -> inspect(String.split(command))
      command -> inspect(command)
    end
  end

  defp observation_command(observation) do
    field(observation, :command) || field(observation, :argv) || field(observation, :tool)
  end

  defp verification_command?(command) when is_binary(command),
    do: command in @execution_tools or command |> String.split() |> verification_argv?()

  defp verification_command?(_command), do: false

  defp verification_argv?([executable | args]) when is_binary(executable) do
    executable = Path.basename(executable)

    executable in @verification_executables or
      verification_subcommand?(executable, args) or
      (executable in ~w(python python3) and Enum.take(args, 2) == ["-m", "pytest"])
  end

  defp verification_argv?(_argv), do: false

  defp verification_subcommand?(executable, [subcommand | _args]) do
    subcommand in Map.get(@verification_subcommands, executable, [])
  end

  defp verification_subcommand?(_executable, _args), do: false

  defp to_string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(_value), do: nil

  defp observation_status(observation) do
    case field(observation, :status) do
      status when status in [:pass, :ok, :completed, :satisfied, "pass", "ok", "completed"] ->
        :pass

      status
      when status in [:fail, :failed, :error, :timeout, :killed, "fail", "failed", "error"] ->
        :fail

      _other ->
        case field(observation, :exit_status) || field(observation, :exit_code) do
          0 -> :pass
          code when is_integer(code) -> :fail
          _other -> :unknown
        end
    end
  end

  defp evidence_metadata(observations, failures) do
    summaries = Enum.map(observations, &observation_summary/1)
    failure_summaries = Enum.map(failures, &observation_summary/1)

    %{
      observed: List.last(failure_summaries) || List.last(summaries),
      observations: summaries,
      failing: failure_summaries
    }
  end

  defp observation_summary(observation) do
    %{
      command: observation_command(observation),
      status: observation_status(observation),
      cwd: field(observation, :cwd),
      exit_status: field(observation, :exit_status) || field(observation, :exit_code),
      output_preview: field(observation, :output_preview) || field(observation, :output)
    }
  end

  defp list_field(value, key), do: value |> field(key) |> List.wrap()

  defp field(value, key) when is_struct(value), do: value |> Map.from_struct() |> field(key)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(_value, _key), do: nil
end
