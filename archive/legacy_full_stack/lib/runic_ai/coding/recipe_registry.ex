defmodule RunicAI.Coding.RecipeRegistry do
  @moduledoc """
  Registry for named standard coding-agent recipes.
  """

  alias RunicAI.Coding.Recipe
  alias RunicAI.Error

  @recipes %{
    explain_repo: %{
      command: "/explain-repo",
      description: "Explain repository structure and important modules without editing.",
      mode: :read_only
    },
    review: %{
      command: "/review",
      description: "Review current diffs or requested files with no mutation.",
      mode: :read_only
    },
    triage_bug: %{
      command: "/triage-bug",
      description: "Investigate a bug report with read/search/git/log tools only.",
      mode: :read_only
    },
    write_tests: %{
      command: "/write-tests",
      description: "Add focused tests and run targeted verification.",
      mode: :verify
    },
    fix_ci: %{
      command: "/fix-ci",
      description: "Use failing command output to repair and rerun verification.",
      mode: :verify
    },
    sandboxed_verify: %{
      command: "/sandboxed-verify",
      description: "Verify with ordinary project tools plus reviewed sandbox code execution.",
      mode: :verify
    },
    polyglot_experiment: %{
      command: "/polyglot-experiment",
      description:
        "Use read/search/git context plus sandboxed code execution without host edits.",
      mode: :read_only
    }
  }

  @spec list() :: [map()]
  def list do
    @recipes
    |> Enum.map(fn {name, metadata} -> Map.put(metadata, :name, name) end)
    |> Enum.sort_by(& &1.name)
  end

  @spec names() :: [atom()]
  def names, do: Map.keys(@recipes) |> Enum.sort()

  @spec fetch(atom() | String.t(), keyword()) :: {:ok, Recipe.t()} | {:error, Error.t()}
  def fetch(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, metadata} <- fetch_metadata(name) do
      {:ok, Recipe.named(name, opts_with_metadata(opts, metadata))}
    end
  end

  @spec fetch!(atom() | String.t(), keyword()) :: Recipe.t()
  def fetch!(name, opts \\ []) do
    case fetch(name, opts) do
      {:ok, recipe} -> recipe
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec metadata(atom() | String.t()) :: {:ok, map()} | {:error, Error.t()}
  def metadata(name) do
    with {:ok, name} <- normalize_name(name),
         {:ok, metadata} <- fetch_metadata(name) do
      {:ok, Map.put(metadata, :name, name)}
    end
  end

  defp fetch_metadata(name) do
    case Map.fetch(@recipes, name) do
      {:ok, metadata} ->
        {:ok, metadata}

      :error ->
        {:error,
         Error.validation("unknown coding recipe",
           source: __MODULE__,
           details: %{recipe: name, known_recipes: names()}
         )}
    end
  end

  defp normalize_name(name) when is_atom(name), do: {:ok, name}

  defp normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.trim_leading("/")
      |> String.replace("-", "_")

    Enum.find_value(names(), {:error, unknown_name(name)}, fn candidate ->
      if Atom.to_string(candidate) == normalized do
        {:ok, candidate}
      end
    end)
  end

  defp normalize_name(name), do: {:error, unknown_name(name)}

  defp unknown_name(name) do
    Error.validation("unknown coding recipe",
      source: __MODULE__,
      details: %{recipe: name, known_recipes: names()}
    )
  end

  defp opts_with_metadata(opts, metadata) do
    Keyword.update(opts, :metadata, metadata, &Map.merge(metadata, &1))
  end
end
