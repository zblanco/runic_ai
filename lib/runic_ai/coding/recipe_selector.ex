defmodule RunicAI.Coding.RecipeSelector do
  @moduledoc """
  Deterministic named-recipe selector for the standard coding agent.

  Callers can provide a classifier function for tests or application-specific
  routing. Without one, selection is conservative and only returns high-signal
  recipes from explicit slash commands or simple keyword heuristics.
  """

  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.RecipeRegistry
  alias RunicAI.Error

  @spec select(String.t(), keyword()) :: {:ok, Recipe.t()} | {:error, Error.t()}
  def select(task, opts \\ [])

  def select(task, opts) when is_binary(task) and is_list(opts) do
    classifier = Keyword.get(opts, :classifier) || Keyword.get(opts, :recipe_classifier)

    candidate =
      cond do
        is_function(classifier, 2) -> classifier.(task, opts)
        is_function(classifier, 1) -> classifier.(task)
        true -> heuristic(task)
      end

    normalize_candidate(candidate)
  end

  def select(task, _opts) do
    {:error,
     Error.validation("coding recipe selection task must be a binary",
       source: __MODULE__,
       details: %{task: task}
     )}
  end

  @spec select!(String.t(), keyword()) :: Recipe.t()
  def select!(task, opts \\ []) do
    case select(task, opts) do
      {:ok, recipe} -> recipe
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_candidate({:ok, %Recipe{} = recipe}), do: {:ok, recipe}
  defp normalize_candidate(%Recipe{} = recipe), do: Recipe.validate(recipe)
  defp normalize_candidate({:ok, name}), do: RecipeRegistry.fetch(name)

  defp normalize_candidate(name) when is_atom(name) or is_binary(name),
    do: RecipeRegistry.fetch(name)

  defp normalize_candidate(nil), do: RecipeRegistry.fetch(:write_tests, mode: :verify)

  defp normalize_candidate({:error, %Error{} = error}), do: {:error, error}

  defp normalize_candidate(other) do
    {:error,
     Error.validation("unsupported coding recipe classifier result",
       source: __MODULE__,
       details: %{result: other}
     )}
  end

  defp heuristic(task) do
    normalized = String.downcase(String.trim(task))

    cond do
      String.starts_with?(normalized, "/explain-repo") ->
        :explain_repo

      String.starts_with?(normalized, "/review") ->
        :review

      String.starts_with?(normalized, "/triage-bug") ->
        :triage_bug

      String.starts_with?(normalized, "/write-tests") ->
        :write_tests

      String.starts_with?(normalized, "/fix-ci") ->
        :fix_ci

      String.contains?(normalized, "ci") and String.contains?(normalized, "fail") ->
        :fix_ci

      String.contains?(normalized, "review") ->
        :review

      String.contains?(normalized, "triage") or String.contains?(normalized, "investigate") ->
        :triage_bug

      String.contains?(normalized, "test") ->
        :write_tests

      true ->
        :write_tests
    end
  end
end
