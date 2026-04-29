defmodule RunicAI.Coding.Command do
  @moduledoc """
  Explicit command invocation contract for coding tools.

  Commands default to direct argv execution. Shell execution is represented
  explicitly and must be allowed by `RunicAI.Coding.CommandPolicy`.
  """

  alias RunicAI.Error

  @valid_backends [:argv, :shell, :just_bash]

  @enforce_keys [:backend, :cwd, :env, :metadata]
  defstruct [:argv, :shell, :timeout_ms, backend: :argv, cwd: ".", env: %{}, metadata: %{}]

  @type backend :: :argv | :shell | :just_bash

  @type t :: %__MODULE__{
          backend: backend(),
          argv: [String.t()] | nil,
          shell: String.t() | nil,
          cwd: Path.t(),
          env: %{optional(String.t()) => String.t()},
          timeout_ms: pos_integer() | :infinity | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    backend = Keyword.get(opts, :backend, :argv)
    cwd = Keyword.get(opts, :cwd, ".")
    env = Keyword.get(opts, :env, %{})
    timeout_ms = Keyword.get(opts, :timeout_ms)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_backend(backend),
         {:ok, argv} <- normalize_argv(backend, opts),
         {:ok, shell} <- normalize_shell(backend, opts),
         :ok <- validate_cwd(cwd),
         {:ok, env} <- normalize_env(env),
         :ok <- validate_timeout(timeout_ms),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         backend: backend,
         argv: argv,
         shell: shell,
         cwd: cwd,
         env: env,
         timeout_ms: timeout_ms,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, command} -> command
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = command), do: validate(command)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      backend: normalize_backend(get(input, :backend, :argv)),
      argv: get(input, :argv, nil),
      command: get(input, :command, nil),
      args: get(input, :args, []),
      shell: get(input, :shell, nil),
      cwd: get(input, :cwd, "."),
      env: get(input, :env, %{}),
      timeout_ms: get(input, :timeout_ms, nil),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.Command-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = command) do
    new(
      backend: command.backend,
      argv: command.argv,
      shell: command.shell,
      cwd: command.cwd,
      env: command.env,
      timeout_ms: command.timeout_ms,
      metadata: command.metadata
    )
  end

  @spec executable(t()) :: String.t() | nil
  def executable(%__MODULE__{backend: :argv, argv: [command | _args]}), do: command
  def executable(%__MODULE__{backend: :shell}), do: "sh"
  def executable(%__MODULE__{backend: :just_bash}), do: "just_bash"
  def executable(%__MODULE__{}), do: nil

  @spec display(t()) :: String.t()
  def display(%__MODULE__{backend: :argv, argv: argv}) when is_list(argv),
    do: Enum.join(argv, " ")

  def display(%__MODULE__{backend: :shell, shell: shell}) when is_binary(shell), do: shell
  def display(%__MODULE__{backend: :just_bash, shell: shell}) when is_binary(shell), do: shell

  defp normalize_backend(backend) when backend in @valid_backends, do: backend
  defp normalize_backend("argv"), do: :argv
  defp normalize_backend("shell"), do: :shell
  defp normalize_backend("just_bash"), do: :just_bash
  defp normalize_backend(backend), do: backend

  defp normalize_argv(:shell, _opts), do: {:ok, nil}
  defp normalize_argv(:just_bash, _opts), do: {:ok, nil}

  defp normalize_argv(:argv, opts) do
    argv = Keyword.get(opts, :argv)
    command = Keyword.get(opts, :command)
    args = Keyword.get(opts, :args, [])

    cond do
      is_list(argv) ->
        validate_argv(argv)

      is_binary(command) ->
        validate_argv([command | args])

      true ->
        {:error,
         Error.validation("argv command requires :argv or :command",
           source: __MODULE__,
           details: %{argv: argv, command: command}
         )}
    end
  end

  defp normalize_shell(:argv, _opts), do: {:ok, nil}

  defp normalize_shell(backend, opts) when backend in [:shell, :just_bash] do
    shell = Keyword.get(opts, :shell) || Keyword.get(opts, :command)

    if is_binary(shell) and shell != "" do
      {:ok, shell}
    else
      {:error,
       Error.validation("shell command requires a non-empty shell string",
         source: __MODULE__,
         details: %{shell: shell}
       )}
    end
  end

  defp validate_backend(backend) when backend in @valid_backends, do: :ok

  defp validate_backend(backend) do
    {:error,
     Error.validation("invalid command backend",
       source: __MODULE__,
       details: %{backend: backend, valid_backends: @valid_backends}
     )}
  end

  defp validate_argv(argv) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &(is_binary(&1) and &1 != "")) do
      {:ok, argv}
    else
      invalid_argv(argv)
    end
  end

  defp validate_argv(argv), do: invalid_argv(argv)

  defp invalid_argv(argv) do
    {:error,
     Error.validation("command argv must be a non-empty list of non-empty strings",
       source: __MODULE__,
       details: %{argv: argv}
     )}
  end

  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "", do: :ok

  defp validate_cwd(cwd) do
    {:error,
     Error.validation("command cwd must be a non-empty workspace-relative path",
       source: __MODULE__,
       details: %{cwd: cwd}
     )}
  end

  defp normalize_env(env) when is_map(env) do
    env
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        is_atom(key) and is_binary(value) ->
          {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

        is_binary(key) and is_binary(value) ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        true ->
          {:halt,
           {:error,
            Error.validation("command env must be a map of stringable keys to string values",
              source: __MODULE__,
              details: %{env: env, key: key, value: value}
            )}}
      end
    end)
  end

  defp normalize_env(env) do
    {:error,
     Error.validation("command env must be a map",
       source: __MODULE__,
       details: %{env: env}
     )}
  end

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_timeout(timeout) do
    {:error,
     Error.validation("command timeout_ms must be nil, :infinity, or a positive integer",
       source: __MODULE__,
       details: %{timeout_ms: timeout}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("command metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
