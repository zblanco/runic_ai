defmodule RunicAI.RLM.Components.SchemaNormalizer do
  @moduledoc """
  Generic JSON-ish response normalizer for generated assistant workflows.
  """

  alias RunicAI.Error

  @spec run(term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(input, _params \\ %{}) do
    text = text(input)

    case decode(text) do
      {:ok, value} ->
        {:ok, %{status: :parsed, value: value}}

      {:error, reason} ->
        {:ok, %{status: :unparsed, value: input, reason: inspect(reason)}}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp decode(text) do
    with {:error, _reason} <- Jason.decode(text),
         {:ok, fenced} <- fenced_json(text) do
      Jason.decode(fenced)
    end
  end

  defp fenced_json(text) do
    case Regex.run(~r/```(?:json)?\s*(.*?)```/s, text) do
      [_match, json] -> {:ok, String.trim(json)}
      _other -> {:error, :no_json_fence}
    end
  end

  defp text(%{text: text}) when is_binary(text), do: text
  defp text(%{"text" => text}) when is_binary(text), do: text
  defp text(value) when is_binary(value), do: value
  defp text(value), do: inspect(value)
end
