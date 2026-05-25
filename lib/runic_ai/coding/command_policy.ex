defmodule RunicAI.Coding.CommandPolicy do
  @moduledoc """
  Guardrails for local command execution.
  """

  alias RunicAI.Coding.Command
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_blocked_commands ~w(rm sudo su shutdown reboot halt mkfs dd)
  @valid_classifications [
    :read_only,
    :writes_workspace,
    :writes_outside_workspace,
    :network,
    :destructive,
    :unknown
  ]

  @default_command_classifications %{
    "cat" => :read_only,
    "echo" => :read_only,
    "elixir" => :unknown,
    "git" => :read_only,
    "just_bash" => :read_only,
    "mix" => :writes_workspace,
    "rg" => :read_only,
    "sh" => :unknown
  }

  @enforce_keys [
    :default_cwd,
    :timeout_ms,
    :max_output_bytes,
    :env_allowlist,
    :allow_shell,
    :allow_just_bash,
    :allowed_commands,
    :blocked_commands,
    :command_classifications,
    :default_classification,
    :metadata
  ]
  defstruct default_cwd: ".",
            timeout_ms: 30_000,
            max_output_bytes: 65_536,
            env_allowlist: [],
            allow_shell: false,
            allow_just_bash: true,
            allowed_commands: nil,
            blocked_commands: @default_blocked_commands,
            command_classifications: @default_command_classifications,
            default_classification: :unknown,
            metadata: %{}

  @type t :: %__MODULE__{
          default_cwd: Path.t(),
          timeout_ms: pos_integer() | :infinity,
          max_output_bytes: pos_integer(),
          env_allowlist: [String.t()],
          allow_shell: boolean(),
          allow_just_bash: boolean(),
          allowed_commands: [String.t()] | nil,
          blocked_commands: [String.t()],
          command_classifications: %{optional(String.t()) => classification()},
          default_classification: classification(),
          metadata: map()
        }

  @type classification ::
          :read_only
          | :writes_workspace
          | :writes_outside_workspace
          | :network
          | :destructive
          | :unknown

  @type authorization :: %{
          required(:cwd) => Path.t(),
          required(:env) => [{String.t(), String.t()}],
          required(:timeout_ms) => pos_integer() | :infinity,
          required(:max_output_bytes) => pos_integer(),
          required(:classification) => classification(),
          required(:network?) => boolean(),
          required(:mutates?) => boolean()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    default_cwd = Keyword.get(opts, :default_cwd, ".")
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, 65_536)
    env_allowlist = Keyword.get(opts, :env_allowlist, [])
    allow_shell = Keyword.get(opts, :allow_shell, false)
    allow_just_bash = Keyword.get(opts, :allow_just_bash, true)
    allowed_commands = Keyword.get(opts, :allowed_commands)
    blocked_commands = Keyword.get(opts, :blocked_commands, @default_blocked_commands)

    command_classifications =
      Keyword.get(opts, :command_classifications, @default_command_classifications)

    default_classification = Keyword.get(opts, :default_classification, :unknown)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_cwd(default_cwd),
         :ok <- validate_timeout(timeout_ms),
         :ok <- validate_max_output_bytes(max_output_bytes),
         :ok <- validate_string_list(env_allowlist, :env_allowlist),
         :ok <- validate_boolean(allow_shell, :allow_shell),
         :ok <- validate_boolean(allow_just_bash, :allow_just_bash),
         :ok <- validate_optional_string_list(allowed_commands, :allowed_commands),
         :ok <- validate_string_list(blocked_commands, :blocked_commands),
         {:ok, command_classifications} <- normalize_classification_map(command_classifications),
         {:ok, default_classification} <- normalize_classification(default_classification),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         default_cwd: default_cwd,
         timeout_ms: timeout_ms,
         max_output_bytes: max_output_bytes,
         env_allowlist: env_allowlist,
         allow_shell: allow_shell,
         allow_just_bash: allow_just_bash,
         allowed_commands: allowed_commands,
         blocked_commands: blocked_commands,
         command_classifications: command_classifications,
         default_classification: default_classification,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      default_cwd: get(input, :default_cwd, "."),
      timeout_ms: get(input, :timeout_ms, 30_000),
      max_output_bytes: get(input, :max_output_bytes, 65_536),
      env_allowlist: get(input, :env_allowlist, []),
      allow_shell: get(input, :allow_shell, false),
      allow_just_bash: get(input, :allow_just_bash, true),
      allowed_commands: get(input, :allowed_commands, nil),
      blocked_commands: get(input, :blocked_commands, @default_blocked_commands),
      command_classifications:
        get(input, :command_classifications, @default_command_classifications),
      default_classification: get(input, :default_classification, :unknown),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.CommandPolicy-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      default_cwd: policy.default_cwd,
      timeout_ms: policy.timeout_ms,
      max_output_bytes: policy.max_output_bytes,
      env_allowlist: policy.env_allowlist,
      allow_shell: policy.allow_shell,
      allow_just_bash: policy.allow_just_bash,
      allowed_commands: policy.allowed_commands,
      blocked_commands: policy.blocked_commands,
      command_classifications: policy.command_classifications,
      default_classification: policy.default_classification,
      metadata: policy.metadata
    )
  end

  @spec classify(t(), Command.t()) :: classification()
  def classify(%__MODULE__{} = policy, %Command{} = command) do
    executable = Command.executable(command)
    basename = executable && Path.basename(executable)

    Map.get(policy.command_classifications, basename, policy.default_classification)
  end

  @spec authorize(t(), Workspace.t(), Command.t()) :: {:ok, authorization()} | {:error, Error.t()}
  def authorize(%__MODULE__{} = policy, %Workspace{} = workspace, %Command{} = command) do
    with :ok <- authorize_shell(policy, command),
         :ok <- authorize_command_name(policy, command),
         :ok <- authorize_env(policy, command.env),
         {:ok, cwd} <- resolve_cwd(workspace, command.cwd || policy.default_cwd) do
      classification = classify(policy, command)

      {:ok,
       %{
         cwd: cwd,
         env: Enum.to_list(command.env),
         timeout_ms: effective_timeout(policy, command),
         max_output_bytes: policy.max_output_bytes,
         classification: classification,
         network?: classification == :network,
         mutates?:
           classification in [
             :writes_workspace,
             :writes_outside_workspace,
             :network,
             :destructive,
             :unknown
           ]
       }}
    end
  end

  defp authorize_shell(_policy, %Command{backend: :argv}), do: :ok
  defp authorize_shell(%__MODULE__{allow_just_bash: true}, %Command{backend: :just_bash}), do: :ok

  defp authorize_shell(_policy, %Command{backend: :just_bash}) do
    blocked_error("just_bash command backend is disabled by command policy", %{
      backend: :just_bash
    })
  end

  defp authorize_shell(%__MODULE__{allow_shell: true}, %Command{backend: :shell}), do: :ok

  defp authorize_shell(_policy, %Command{backend: :shell}) do
    blocked_error("shell command backend is disabled by command policy", %{backend: :shell})
  end

  defp authorize_command_name(policy, command) do
    executable = Command.executable(command)
    basename = executable && Path.basename(executable)

    cond do
      is_nil(basename) ->
        blocked_error("command has no executable", %{command: command})

      basename in policy.blocked_commands ->
        blocked_error("command is blocked by command policy", %{command: basename})

      is_list(policy.allowed_commands) and basename not in policy.allowed_commands and
          not hitl_approved?(command) ->
        blocked_error("command is not in the command allowlist", %{
          command: basename,
          allowed_commands: policy.allowed_commands
        })

      true ->
        :ok
    end
  end

  defp hitl_approved?(%Command{metadata: metadata}) when is_map(metadata) do
    get(metadata, :hitl_approved?, false) in [true, "true"]
  end

  defp hitl_approved?(_command), do: false

  defp authorize_env(%__MODULE__{env_allowlist: allowlist}, env) do
    denied = env |> Map.keys() |> Enum.reject(&(&1 in allowlist))

    case denied do
      [] ->
        :ok

      denied ->
        blocked_error("command env contains keys outside the allowlist", %{
          denied_env_keys: denied,
          env_allowlist: allowlist
        })
    end
  end

  defp resolve_cwd(workspace, cwd) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, cwd, :read) do
      if File.dir?(resolved.path) do
        {:ok, resolved.path}
      else
        {:error,
         Error.validation("command cwd must resolve to a directory",
           source: __MODULE__,
           details: %{cwd: cwd, path: resolved.path}
         )}
      end
    end
  end

  defp effective_timeout(%__MODULE__{timeout_ms: policy_timeout}, %Command{timeout_ms: nil}) do
    policy_timeout
  end

  defp effective_timeout(%__MODULE__{timeout_ms: :infinity}, %Command{timeout_ms: command_timeout}) do
    command_timeout || :infinity
  end

  defp effective_timeout(%__MODULE__{timeout_ms: policy_timeout}, %Command{
         timeout_ms: :infinity
       }) do
    policy_timeout
  end

  defp effective_timeout(%__MODULE__{timeout_ms: policy_timeout}, %Command{
         timeout_ms: command_timeout
       })
       when is_integer(policy_timeout) and is_integer(command_timeout) do
    min(policy_timeout, command_timeout)
  end

  defp blocked_error(message, details) do
    {:error,
     Error.new(:blocked, message,
       source: __MODULE__,
       details: details
     )}
  end

  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "", do: :ok

  defp validate_cwd(cwd) do
    {:error,
     Error.validation("command policy default_cwd must be a non-empty string",
       source: __MODULE__,
       details: %{default_cwd: cwd}
     )}
  end

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_timeout(timeout) do
    {:error,
     Error.validation("command policy timeout_ms must be :infinity or a positive integer",
       source: __MODULE__,
       details: %{timeout_ms: timeout}
     )}
  end

  defp validate_max_output_bytes(bytes) when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_max_output_bytes(bytes) do
    {:error,
     Error.validation("command policy max_output_bytes must be a positive integer",
       source: __MODULE__,
       details: %{max_output_bytes: bytes}
     )}
  end

  defp validate_string_list(list, _field) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      :ok
    else
      invalid_string_list(list)
    end
  end

  defp validate_string_list(list, _field), do: invalid_string_list(list)

  defp validate_optional_string_list(nil, _field), do: :ok
  defp validate_optional_string_list(list, field), do: validate_string_list(list, field)

  defp invalid_string_list(value) do
    {:error,
     Error.validation("command policy string-list fields must contain only strings",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("command policy #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_classification_map(classifications) when is_map(classifications) do
    classifications
    |> Enum.reduce_while({:ok, %{}}, fn {command, classification}, {:ok, acc} ->
      with true <- is_binary(command),
           {:ok, classification} <- normalize_classification(classification) do
        {:cont, {:ok, Map.put(acc, command, classification)}}
      else
        false ->
          {:halt,
           {:error,
            Error.validation("command classification keys must be strings",
              source: __MODULE__,
              details: %{command_classifications: classifications}
            )}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_classification_map(classifications) do
    {:error,
     Error.validation("command_classifications must be a map",
       source: __MODULE__,
       details: %{command_classifications: classifications}
     )}
  end

  defp normalize_classification(classification) when classification in @valid_classifications,
    do: {:ok, classification}

  defp normalize_classification(classification) when is_binary(classification) do
    case classification do
      "read_only" -> {:ok, :read_only}
      "writes_workspace" -> {:ok, :writes_workspace}
      "writes_outside_workspace" -> {:ok, :writes_outside_workspace}
      "network" -> {:ok, :network}
      "destructive" -> {:ok, :destructive}
      "unknown" -> {:ok, :unknown}
      _ -> invalid_classification(classification)
    end
  end

  defp normalize_classification(classification), do: invalid_classification(classification)

  defp invalid_classification(classification) do
    {:error,
     Error.validation("invalid command classification",
       source: __MODULE__,
       details: %{classification: classification, valid_classifications: @valid_classifications}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("command policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
