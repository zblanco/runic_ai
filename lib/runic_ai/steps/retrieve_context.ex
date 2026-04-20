defmodule RunicAI.Steps.RetrieveContext do
  @moduledoc """
  Retrieve external context through a backend-neutral provider contract.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Context.Focus
  alias RunicAI.Retrieval.Document
  alias RunicAI.Retrieval.Query
  alias RunicAI.Retrieval.Result

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :retrieve_context)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, %Focus{} = focus ->
        retrieve!(turn_request, focus, options)
      end,
      name: name
    )
  end

  @spec retrieve(TurnRequest.t(), Focus.t(), keyword()) ::
          {:ok, Result.t()} | {:error, RunicAI.Error.t()}
  def retrieve(%TurnRequest{} = turn_request, %Focus{} = focus, opts \\ []) do
    provider = Keyword.get(opts, :provider)

    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, focus} <- Focus.validate(focus),
         {:ok, query} <-
           Query.new(
             text: Keyword.get(opts, :text, focus.goal),
             filters: Keyword.get(opts, :filters, %{}),
             scope:
               Keyword.get(opts, :scope, turn_request.metadata[:retrieval_scope] || :default),
             top_k: Keyword.get(opts, :top_k, 5),
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      resolve_result(query, provider, opts)
    end
  end

  @spec retrieve!(TurnRequest.t(), Focus.t(), keyword()) :: Result.t()
  def retrieve!(%TurnRequest{} = turn_request, %Focus{} = focus, opts \\ []) do
    case retrieve(turn_request, focus, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp resolve_result(%Query{} = query, nil, _opts),
    do: {:ok, Result.new!(query, documents: [], provider: :none)}

  defp resolve_result(%Query{} = query, documents, _opts) when is_list(documents) do
    docs =
      documents
      |> Enum.filter(&match?(%Document{}, &1))
      |> rank_local(query)
      |> Enum.take(query.top_k)

    Result.new(query, documents: docs, provider: :list)
  end

  defp resolve_result(%Query{} = query, provider, opts) when is_function(provider, 2) do
    case provider.(query, Keyword.get(opts, :provider_opts, [])) do
      {:ok, %Result{} = result} ->
        Result.validate(result)

      {:ok, documents} when is_list(documents) ->
        Result.new(query, documents: documents, provider: :function)

      {:error, _} ->
        {:ok, Result.new!(query, documents: [], provider: :function)}

      _ ->
        {:ok, Result.new!(query, documents: [], provider: :function)}
    end
  end

  defp resolve_result(%Query{} = query, provider, opts) when is_atom(provider) do
    case provider.retrieve(query, Keyword.get(opts, :provider_opts, [])) do
      {:ok, %Result{} = result} ->
        Result.validate(result)

      {:ok, documents} when is_list(documents) ->
        Result.new(query, documents: documents, provider: provider)

      {:error, _} ->
        {:ok, Result.new!(query, documents: [], provider: provider)}

      _ ->
        {:ok, Result.new!(query, documents: [], provider: provider)}
    end
  end

  defp rank_local(documents, %Query{text: text}) do
    terms =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_:-]+/u, trim: true)

    documents
    |> Enum.map(fn document ->
      haystack = String.downcase(document.content)
      score = Enum.count(terms, &String.contains?(haystack, &1))
      %{document | score: document.score || score}
    end)
    |> Enum.sort_by(&{-(&1.score || 0), &1.id})
  end
end
