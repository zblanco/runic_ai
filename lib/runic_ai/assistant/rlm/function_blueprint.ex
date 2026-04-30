defmodule RunicAI.Assistant.RLM.FunctionBlueprint do
  @moduledoc """
  Data contract for generated assistant workflow functions.

  The blueprint is deliberately data-first. Tier 0 names a parameterized
  built-in operation. Tier 1 carries a restricted expression tree interpreted by
  trusted RunicAI code. Tier 2 is represented for planning/policy purposes, but
  is not executable in the first assistant implementation.
  """

  alias RunicAI.Error

  @tiers [:tier0, :tier1, :tier2]
  @tier0_ops [
    :identity,
    :get,
    :pick,
    :flatten,
    :group_by,
    :dedupe_by,
    :sort_by,
    :join,
    :template,
    :json_encode,
    :concat,
    :count
  ]

  @enforce_keys [:tier]
  @derive Jason.Encoder
  defstruct [
    :tier,
    :op,
    :expr,
    :source,
    inputs: [],
    outputs: [],
    metadata: %{}
  ]

  @type tier :: :tier0 | :tier1 | :tier2
  @type op ::
          :identity
          | :get
          | :pick
          | :flatten
          | :group_by
          | :dedupe_by
          | :sort_by
          | :join
          | :template
          | :json_encode
          | :concat
          | :count

  @type t :: %__MODULE__{
          tier: tier(),
          op: op() | nil,
          expr: term(),
          source: String.t() | nil,
          inputs: [String.t()],
          outputs: [String.t()],
          metadata: map()
        }

  @spec tier0(op(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def tier0(op, opts \\ []) when is_list(opts) do
    new(:tier0,
      op: op,
      expr: Keyword.get(opts, :expr),
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec tier1(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def tier1(expr, opts \\ []) when is_list(opts) do
    new(:tier1,
      expr: expr,
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec new(tier() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(tier, opts \\ []) when is_list(opts) do
    with {:ok, tier} <- normalize_tier(tier),
         {:ok, op} <- normalize_op(Keyword.get(opts, :op)),
         :ok <- validate_tier_op(tier, op),
         :ok <- validate_source(tier, Keyword.get(opts, :source)),
         :ok <- validate_list(Keyword.get(opts, :inputs, []), :inputs),
         :ok <- validate_list(Keyword.get(opts, :outputs, []), :outputs),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         tier: tier,
         op: op,
         expr: Keyword.get(opts, :expr),
         source: Keyword.get(opts, :source),
         inputs: Keyword.get(opts, :inputs, []),
         outputs: Keyword.get(opts, :outputs, []),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(tier() | String.t(), keyword()) :: t()
  def new!(tier, opts \\ []) do
    case new(tier, opts) do
      {:ok, blueprint} -> blueprint
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = blueprint), do: validate(blueprint)
  def from_input(input) when is_list(input), do: input |> Map.new() |> from_input()

  def from_input(input) when is_map(input) do
    new(get(input, :tier, nil),
      op: get(input, :op, nil),
      expr: get(input, :expr, nil),
      source: get(input, :source, nil),
      inputs: get(input, :inputs, []),
      outputs: get(input, :outputs, []),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("expected an assistant function blueprint",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = blueprint) do
    new(blueprint.tier,
      op: blueprint.op,
      expr: blueprint.expr,
      source: blueprint.source,
      inputs: blueprint.inputs,
      outputs: blueprint.outputs,
      metadata: blueprint.metadata
    )
  end

  @spec tiers() :: [tier()]
  def tiers, do: @tiers

  @spec tier0_ops() :: [op()]
  def tier0_ops, do: @tier0_ops

  @spec tier_rank(tier()) :: non_neg_integer()
  def tier_rank(:tier0), do: 0
  def tier_rank(:tier1), do: 1
  def tier_rank(:tier2), do: 2

  defp normalize_tier(:tier0), do: {:ok, :tier0}
  defp normalize_tier(:tier1), do: {:ok, :tier1}
  defp normalize_tier(:tier2), do: {:ok, :tier2}
  defp normalize_tier(0), do: {:ok, :tier0}
  defp normalize_tier(1), do: {:ok, :tier1}
  defp normalize_tier(2), do: {:ok, :tier2}
  defp normalize_tier("0"), do: {:ok, :tier0}
  defp normalize_tier("1"), do: {:ok, :tier1}
  defp normalize_tier("2"), do: {:ok, :tier2}
  defp normalize_tier("tier0"), do: {:ok, :tier0}
  defp normalize_tier("tier_0"), do: {:ok, :tier0}
  defp normalize_tier("tier1"), do: {:ok, :tier1}
  defp normalize_tier("tier_1"), do: {:ok, :tier1}
  defp normalize_tier("tier2"), do: {:ok, :tier2}
  defp normalize_tier("tier_2"), do: {:ok, :tier2}

  defp normalize_tier(tier) do
    {:error,
     Error.validation("invalid assistant function blueprint tier",
       source: __MODULE__,
       details: %{tier: tier, valid: @tiers}
     )}
  end

  defp normalize_op(nil), do: {:ok, nil}
  defp normalize_op(op) when op in @tier0_ops, do: {:ok, op}

  defp normalize_op(op) when is_binary(op) do
    normalized = op |> String.downcase() |> String.replace("-", "_")

    case Enum.find(@tier0_ops, &(Atom.to_string(&1) == normalized)) do
      nil ->
        {:error,
         Error.validation("invalid assistant function blueprint operation",
           source: __MODULE__,
           details: %{op: op, valid: @tier0_ops}
         )}

      op ->
        {:ok, op}
    end
  end

  defp normalize_op(op) do
    {:error,
     Error.validation("invalid assistant function blueprint operation",
       source: __MODULE__,
       details: %{op: op, valid: @tier0_ops}
     )}
  end

  defp validate_tier_op(:tier0, nil) do
    {:error,
     Error.validation("tier0 function blueprints require a built-in operation",
       source: __MODULE__
     )}
  end

  defp validate_tier_op(:tier0, op) when op in @tier0_ops, do: :ok
  defp validate_tier_op(:tier1, _op), do: :ok
  defp validate_tier_op(:tier2, _op), do: :ok

  defp validate_source(:tier2, source) when is_binary(source) and source != "", do: :ok

  defp validate_source(:tier2, source) do
    {:error,
     Error.validation("tier2 function blueprints require source text",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp validate_source(_tier, nil), do: :ok
  defp validate_source(_tier, source) when is_binary(source), do: :ok

  defp validate_source(_tier, source) do
    {:error,
     Error.validation("function blueprint source must be a string or nil",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp validate_list(values, _field) when is_list(values), do: :ok

  defp validate_list(values, field) do
    {:error,
     Error.validation("function blueprint #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: values}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("function blueprint metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
