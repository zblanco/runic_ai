defmodule RunicAI.Coding.Profile do
  @moduledoc """
  Language and project profile for common local coding workflows.
  """

  alias RunicAI.Error

  @enforce_keys [:name, :language, :commands, :metadata]
  defstruct [:name, :language, :commands, :metadata]

  @type task :: :compile_project | :run_tests | :run_formatter | :run_linter

  @type t :: %__MODULE__{
          name: atom(),
          language: atom(),
          commands: %{optional(task()) => [String.t()]},
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, :generic)
    language = Keyword.get(opts, :language, :unknown)
    commands = Keyword.get(opts, :commands, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_atom(name, :name),
         :ok <- validate_atom(language, :language),
         {:ok, commands} <- normalize_commands(commands),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{name: name, language: language, commands: commands, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, profile} -> profile
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec generic(keyword()) :: t()
  def generic(opts \\ []) do
    new!(
      Keyword.merge(
        [
          name: :generic,
          language: :unknown,
          commands: %{},
          metadata: %{detected_by: __MODULE__}
        ],
        opts
      )
    )
  end

  @spec mix(keyword()) :: t()
  def mix(opts \\ []) do
    new!(
      Keyword.merge(
        [
          name: :mix,
          language: :elixir,
          commands: %{
            compile_project: ["mix", "compile"],
            run_tests: ["mix", "test"],
            run_formatter: ["mix", "format"],
            run_linter: ["mix", "format", "--check-formatted"]
          },
          metadata: %{detected_by: __MODULE__}
        ],
        opts
      )
    )
  end

  @spec detect(Path.t() | %{root: Path.t()}) :: {:ok, t()} | {:error, Error.t()}
  def detect(%{root: root}), do: detect(root)

  def detect(root) when is_binary(root) do
    cond do
      File.exists?(Path.join(root, "mix.exs")) -> {:ok, mix()}
      true -> {:ok, generic()}
    end
  end

  def detect(root) do
    {:error,
     Error.validation("profile detection requires a root path",
       source: __MODULE__,
       details: %{root: root}
     )}
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: {:ok, generic()}
  def from_input(%__MODULE__{} = profile), do: validate(profile)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      name: get(input, :name, :generic),
      language: get(input, :language, :unknown),
      commands: get(input, :commands, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.Profile-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, profile} -> profile
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = profile) do
    new(
      name: profile.name,
      language: profile.language,
      commands: profile.commands,
      metadata: profile.metadata
    )
  end

  @spec command(t(), task()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def command(%__MODULE__{commands: commands}, task) when is_atom(task) do
    case Map.fetch(commands, task) do
      {:ok, argv} ->
        {:ok, argv}

      :error ->
        {:error,
         Error.validation("profile does not define command for task",
           source: __MODULE__,
           details: %{task: task, available_tasks: Map.keys(commands)}
         )}
    end
  end

  defp normalize_commands(commands) when is_map(commands) do
    commands
    |> Enum.reduce_while({:ok, %{}}, fn {task, argv}, {:ok, acc} ->
      with {:ok, task} <- normalize_task(task),
           {:ok, argv} <- normalize_argv(argv) do
        {:cont, {:ok, Map.put(acc, task, argv)}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_commands(commands) when is_list(commands),
    do: normalize_commands(Map.new(commands))

  defp normalize_commands(commands) do
    {:error,
     Error.validation("profile commands must be a map or keyword list",
       source: __MODULE__,
       details: %{commands: commands}
     )}
  end

  defp normalize_task(task) when is_atom(task), do: {:ok, task}

  defp normalize_task(task) when is_binary(task) do
    case task do
      "compile_project" ->
        {:ok, :compile_project}

      "run_tests" ->
        {:ok, :run_tests}

      "run_formatter" ->
        {:ok, :run_formatter}

      "run_linter" ->
        {:ok, :run_linter}

      other ->
        {:error,
         Error.validation("unknown profile task",
           source: __MODULE__,
           details: %{task: other}
         )}
    end
  end

  defp normalize_task(task) do
    {:error,
     Error.validation("profile command task must be an atom or known string",
       source: __MODULE__,
       details: %{task: task}
     )}
  end

  defp normalize_argv(argv) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &is_binary/1) do
      {:ok, argv}
    else
      invalid_argv(argv)
    end
  end

  defp normalize_argv(argv), do: invalid_argv(argv)

  defp invalid_argv(argv) do
    {:error,
     Error.validation("profile command argv must be a non-empty list of strings",
       source: __MODULE__,
       details: %{argv: argv}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("profile #{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("profile metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
