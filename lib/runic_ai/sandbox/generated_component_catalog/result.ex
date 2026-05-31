defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Result do
  @moduledoc """
  Ranked generated component catalog search result.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry

  @enforce_keys [:entry, :score, :reasons, :metadata]
  @derive Jason.Encoder
  defstruct [:entry, :score, :reasons, :metadata]

  @type t :: %__MODULE__{
          entry: Entry.t(),
          score: number(),
          reasons: [atom()],
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with {:ok, entry} <- Entry.validate(get(input, :entry)),
         :ok <- validate_score(get(input, :score)),
         {:ok, reasons} <- normalize_reasons(get(input, :reasons, [])),
         {:ok, metadata} <- normalize_metadata(get(input, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         entry: entry,
         score: get(input, :score),
         reasons: reasons,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_score(score) when is_number(score), do: :ok

  defp validate_score(score) do
    {:error,
     Error.validation("generated component catalog result score must be numeric",
       source: __MODULE__,
       details: %{score: score}
     )}
  end

  defp normalize_reasons(reasons) when is_list(reasons) do
    if Enum.all?(reasons, &is_atom/1) do
      {:ok, reasons}
    else
      {:error,
       Error.validation("generated component catalog result reasons must contain atoms",
         source: __MODULE__,
         details: %{reasons: reasons}
       )}
    end
  end

  defp normalize_reasons(reasons) do
    {:error,
     Error.validation("generated component catalog result reasons must be a list",
       source: __MODULE__,
       details: %{reasons: reasons}
     )}
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}

  defp normalize_metadata(metadata) do
    {:error,
     Error.validation("generated component catalog result metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
