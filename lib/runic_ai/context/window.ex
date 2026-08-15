defmodule RunicAI.Context.Window do
  @moduledoc "A bounded, ordered context selection produced by a host retrieval adapter."

  alias RunicAI.Context.Reference
  alias RunicAI.JSONValue

  @wire_id "runic.ai/context-window/v1"
  @enforce_keys [:references]
  defstruct references: [], query: nil, truncated: false, metadata: %{}

  @type t :: %__MODULE__{
          references: [Reference.t()],
          query: String.t() | nil,
          truncated: boolean(),
          metadata: map()
        }

  def new(references, opts \\ []) when is_list(references) do
    with {:ok, references} <- normalize_references(references),
         query when is_nil(query) or is_binary(query) <- Keyword.get(opts, :query),
         truncated when is_boolean(truncated) <- Keyword.get(opts, :truncated, false),
         {:ok, metadata} <- JSONValue.normalize(Keyword.get(opts, :metadata, %{})),
         true <- is_map(metadata) do
      {:ok,
       %__MODULE__{references: references, query: query, truncated: truncated, metadata: metadata}}
    else
      {:error, issues} -> {:error, issues}
      _other -> issue([], "context window is invalid")
    end
  end

  def new!(references, opts \\ []) do
    case new(references, opts) do
      {:ok, window} -> window
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = window),
    do:
      %{
        "$contract" => @wire_id,
        "references" => Enum.map(window.references, &Reference.encode/1),
        "truncated" => window.truncated,
        "metadata" => window.metadata
      }
      |> put_if("query", window.query)

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- map["$contract"] == @wire_id do
      new(Map.get(map, "references", []),
        query: map["query"],
        truncated: Map.get(map, "truncated", false),
        metadata: Map.get(map, "metadata", %{})
      )
    else
      false -> issue(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> issue([], "context window must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  defp normalize_references(references) do
    references
    |> Enum.reduce({:ok, []}, fn reference, acc ->
      case {acc, normalize_reference(reference)} do
        {{:ok, values}, {:ok, normalized}} -> {:ok, [normalized | values]}
        {{:ok, _values}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_reference(%Reference{} = reference),
    do: Reference.new(Reference.encode(reference))

  defp normalize_reference(reference), do: Reference.decode(reference)
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp issue(path, message), do: {:error, [%{path: path, message: message}]}
end
