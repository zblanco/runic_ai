defmodule RunicAI.Tool.Definition do
  @moduledoc """
  Canonical model-visible and workflow-executable tool definition.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.ExecutionPolicy

  @enforce_keys [:name, :description, :parameter_schema, :executor, :execution_policy, :metadata]
  defstruct [:name, :description, :parameter_schema, :executor, :execution_policy, :metadata]

  @type executor ::
          ReqLLM.Tool.callback()
          | (map() -> {:ok, term()} | {:error, term()})
          | {module(), atom()}
          | {module(), atom(), list()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameter_schema: keyword() | map(),
          executor: executor(),
          execution_policy: ExecutionPolicy.t(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)
    parameter_schema = Keyword.get(opts, :parameter_schema, [])
    executor = Keyword.get(opts, :executor)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_name(name),
         :ok <- validate_description(description),
         :ok <- validate_parameter_schema(parameter_schema),
         :ok <- validate_executor(executor),
         {:ok, execution_policy} <-
           ExecutionPolicy.from_input(Keyword.get(opts, :execution_policy)),
         :ok <- validate_metadata(metadata),
         {:ok, _req_tool} <- to_req_llm_tool_data(name, description, parameter_schema, executor) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         parameter_schema: parameter_schema,
         executor: executor,
         execution_policy: execution_policy,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, definition} -> definition
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = definition) do
    new(
      name: definition.name,
      description: definition.description,
      parameter_schema: definition.parameter_schema,
      executor: definition.executor,
      execution_policy: definition.execution_policy,
      metadata: definition.metadata
    )
  end

  @spec to_req_llm_tool(t()) :: {:ok, ReqLLM.Tool.t()} | {:error, Error.t()}
  def to_req_llm_tool(%__MODULE__{} = definition) do
    with {:ok, definition} <- validate(definition),
         {:ok, req_tool} <-
           to_req_llm_tool_data(
             definition.name,
             definition.description,
             definition.parameter_schema,
             definition.executor
           ) do
      {:ok, req_tool}
    end
  end

  @spec to_req_llm_tool!(t()) :: ReqLLM.Tool.t()
  def to_req_llm_tool!(%__MODULE__{} = definition) do
    case to_req_llm_tool(definition) do
      {:ok, req_tool} -> req_tool
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate_arguments(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def validate_arguments(%__MODULE__{} = definition, arguments) when is_map(arguments) do
    validation_tool =
      ReqLLM.Tool.new!(
        name: definition.name,
        description: definition.description,
        parameter_schema: definition.parameter_schema,
        callback: fn validated_arguments -> {:ok, validated_arguments} end
      )

    case ReqLLM.Tool.execute(validation_tool, arguments) do
      {:ok, validated_arguments} ->
        {:ok, validated_arguments}

      {:error, reason} ->
        {:error,
         normalize_req_llm_error(reason,
           kind: :validation,
           message: "tool arguments failed validation"
         )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :validation, source: __MODULE__)}
  end

  def validate_arguments(%__MODULE__{}, arguments) do
    {:error,
     Error.validation("tool arguments must be a map, got: #{inspect(arguments)}",
       source: __MODULE__
     )}
  end

  @spec execute(t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def execute(%__MODULE__{} = definition, arguments) when is_map(arguments) do
    with {:ok, req_tool} <- to_req_llm_tool(definition) do
      case ReqLLM.Tool.execute(req_tool, arguments) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, normalize_req_llm_error(reason, message: "tool execution failed")}
      end
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, kind: :unexpected, source: __MODULE__)}
  end

  def execute(%__MODULE__{}, arguments) do
    {:error,
     Error.validation("tool arguments must be a map, got: #{inspect(arguments)}",
       source: __MODULE__
     )}
  end

  defp to_req_llm_tool_data(name, description, parameter_schema, executor) do
    case ReqLLM.Tool.new(
           name: name,
           description: description,
           parameter_schema: parameter_schema,
           callback: executor
         ) do
      {:ok, req_tool} ->
        {:ok, req_tool}

      {:error, reason} ->
        {:error, normalize_req_llm_error(reason, message: "invalid tool definition")}
    end
  end

  defp validate_name(name) when is_binary(name) and name != "" do
    if ReqLLM.Tool.valid_name?(name) do
      :ok
    else
      {:error,
       Error.validation("invalid tool name: #{inspect(name)}",
         source: __MODULE__,
         details: %{name: name}
       )}
    end
  end

  defp validate_name(name) do
    {:error,
     Error.validation("tool name must be a non-empty string, got: #{inspect(name)}",
       source: __MODULE__
     )}
  end

  defp validate_description(description) when is_binary(description) and description != "",
    do: :ok

  defp validate_description(description) do
    {:error,
     Error.validation("tool description must be a non-empty string, got: #{inspect(description)}",
       source: __MODULE__
     )}
  end

  defp validate_parameter_schema(parameter_schema) when is_list(parameter_schema), do: :ok
  defp validate_parameter_schema(parameter_schema) when is_map(parameter_schema), do: :ok

  defp validate_parameter_schema(parameter_schema) do
    {:error,
     Error.validation(
       "tool parameter_schema must be a keyword list or map, got: #{inspect(parameter_schema)}",
       source: __MODULE__
     )}
  end

  defp validate_executor(executor) when is_function(executor, 1), do: :ok
  defp validate_executor({module, function}) when is_atom(module) and is_atom(function), do: :ok

  defp validate_executor({module, function, extra_args})
       when is_atom(module) and is_atom(function) and is_list(extra_args),
       do: :ok

  defp validate_executor(executor) do
    {:error,
     Error.validation("tool executor must be a function or MFA, got: #{inspect(executor)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp normalize_req_llm_error(reason, opts) do
    kind = Keyword.get(opts, :kind, classify_req_llm_error(reason))
    message = Keyword.get(opts, :message, inspect(reason))

    case reason do
      %Error{} = error ->
        error

      other ->
        Error.from_reason(other, kind: kind, message: message, source: __MODULE__)
    end
  end

  defp classify_req_llm_error(%{__struct__: struct}) do
    name =
      struct
      |> Module.split()
      |> Enum.join(".")

    if String.contains?(name, "Validation") or String.contains?(name, "Invalid") do
      :validation
    else
      :unexpected
    end
  end

  defp classify_req_llm_error(_reason), do: :unexpected
end
