defmodule RunicAI.LLM.Request do
  @moduledoc """
  Canonical request contract for LLM text generation.
  """

  alias RunicAI.Error
  alias RunicAI.Prompt

  @enforce_keys [:model, :prompt]
  defstruct [:model, :prompt, opts: [], metadata: %{}]

  @type prompt :: Prompt.t() | String.t()

  @type t :: %__MODULE__{
          model: String.t() | {atom(), String.t()} | map(),
          prompt: prompt(),
          opts: keyword(),
          metadata: map()
        }

  @request_keys [:model, :prompt, :opts, :metadata]

  @spec new(String.t() | {atom(), String.t()} | map(), prompt(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(model, prompt, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    llm_opts = normalize_opts(opts)

    with :ok <- validate_model(model),
         :ok <- validate_prompt(prompt),
         :ok <- validate_metadata(metadata),
         :ok <- validate_opts(llm_opts) do
      {:ok, %__MODULE__{model: model, prompt: prompt, opts: llm_opts, metadata: metadata}}
    end
  end

  @spec new!(String.t() | {atom(), String.t()} | map(), prompt(), keyword()) :: t()
  def new!(model, prompt, opts \\ []) do
    case new(model, prompt, opts) do
      {:ok, request} -> request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = request) do
    with :ok <- validate_model(request.model),
         :ok <- validate_prompt(request.prompt),
         :ok <- validate_metadata(request.metadata),
         :ok <- validate_opts(request.opts) do
      {:ok, request}
    end
  end

  @spec from_input(t() | Prompt.t() | String.t() | map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = request, _defaults), do: validate(request)

  def from_input(%Prompt{} = prompt, defaults) when is_list(defaults) do
    build_from_parts(Keyword.get(defaults, :model), prompt, defaults)
  end

  def from_input(prompt, defaults) when is_binary(prompt) and is_list(defaults) do
    build_from_parts(Keyword.get(defaults, :model), prompt, defaults)
  end

  def from_input(input, defaults) when is_map(input) and is_list(defaults) do
    model = Map.get(input, :model, Keyword.get(defaults, :model))
    prompt = Map.get(input, :prompt)

    metadata =
      merge_metadata(Keyword.get(defaults, :metadata, %{}), Map.get(input, :metadata, %{}))

    opts = merge_opts(extract_opts(defaults), extract_opts(input))

    if is_nil(prompt) do
      {:error,
       Error.validation("LLM request input must include :prompt",
         source: __MODULE__,
         details: %{input: input}
       )}
    else
      new(model, prompt, opts: opts, metadata: metadata)
    end
  end

  def from_input(other, _defaults) do
    {:error,
     Error.validation("expected an LLM request-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp build_from_parts(nil, _prompt, _defaults) do
    {:error,
     Error.validation("LLM request requires a model",
       source: __MODULE__,
       details: %{required: :model}
     )}
  end

  defp build_from_parts(model, prompt, defaults) do
    metadata = Keyword.get(defaults, :metadata, %{})
    opts = extract_opts(defaults)
    new(model, prompt, opts: opts, metadata: metadata)
  end

  defp validate_model(model) when is_binary(model), do: :ok
  defp validate_model({provider, model}) when is_atom(provider) and is_binary(model), do: :ok
  defp validate_model(model) when is_map(model), do: :ok

  defp validate_model(model) do
    {:error,
     Error.validation("invalid LLM model specification: #{inspect(model)}",
       source: __MODULE__
     )}
  end

  defp validate_prompt(%Prompt{} = prompt) do
    case Prompt.validate(prompt) do
      {:ok, _prompt} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt), do: :ok

  defp validate_prompt(prompt) do
    {:error,
     Error.validation("LLM prompt must be a string or RunicAI.Prompt, got: #{inspect(prompt)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("LLM request metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp validate_opts(opts) when is_list(opts), do: :ok

  defp validate_opts(opts) do
    {:error,
     Error.validation("LLM request opts must be a keyword list, got: #{inspect(opts)}",
       source: __MODULE__
     )}
  end

  defp extract_opts(opts) when is_list(opts) do
    {nested_opts, rest} = Keyword.pop(opts, :opts, [])
    nested_opts ++ Keyword.drop(rest, @request_keys)
  end

  defp extract_opts(input) when is_map(input) do
    nested_opts = Map.get(input, :opts, [])

    input
    |> Map.drop(@request_keys)
    |> Enum.into([])
    |> Kernel.++(nested_opts)
    |> Enum.reverse()
    |> Enum.reduce([], fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  defp normalize_opts(opts) do
    extract_opts(opts)
  end

  defp merge_opts(defaults, overrides) do
    Keyword.merge(defaults, overrides)
  end

  defp merge_metadata(defaults, overrides) when is_map(defaults) and is_map(overrides) do
    Map.merge(defaults, overrides)
  end
end
