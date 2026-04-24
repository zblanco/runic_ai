defmodule RunicAI.RLM do
  @moduledoc """
  Facade for RunicAI's recursive long-context execution contracts.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Environments.InMemory
  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.Planner
  alias RunicAI.RLM.Slice
  alias RunicAI.RLM.SliceSet

  @spec init_environment(module(), keyword()) :: {:ok, term()} | {:error, term()}
  @spec init_environment(keyword()) :: {:ok, term()} | {:error, term()}
  def init_environment(module \\ InMemory, opts \\ [])

  def init_environment(opts, []) when is_list(opts), do: init_environment(InMemory, opts)

  def init_environment(module, opts) when is_atom(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :init, 1) do
      module.init(opts)
    else
      {:error,
       Error.validation("RLM environment must implement init/1",
         source: __MODULE__,
         details: %{module: module}
       )}
    end
  end

  @spec put_source(term(), String.t(), keyword()) ::
          {:ok, EnvironmentRef.t(), term()} | {:error, term()}
  def put_source(environment, content, opts \\ []) when is_binary(content) and is_list(opts) do
    with {:ok, module} <- environment_module(environment, :put_source, 3) do
      module.put_source(environment, content, opts)
    end
  end

  @spec source(term(), EnvironmentRef.t()) :: {:ok, term()} | {:error, term()}
  def source(environment, %EnvironmentRef{} = ref) do
    with {:ok, module} <- environment_module(environment, :get_source, 2) do
      module.get_source(environment, ref)
    end
  end

  @spec split(term(), EnvironmentRef.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def split(environment, %EnvironmentRef{} = ref, opts \\ []) when is_list(opts) do
    with {:ok, module} <- environment_module(environment, :split, 3) do
      module.split(environment, ref, opts)
    end
  end

  @spec materialize(term(), EnvironmentRef.t() | Slice.t() | SliceSet.t(), keyword()) ::
          {:ok, term() | [term()]} | {:error, term()}
  def materialize(environment, ref_or_slice, opts \\ [])

  def materialize(environment, %SliceSet{} = slice_set, opts) when is_list(opts) do
    Enum.reduce_while(slice_set.slices, {:ok, []}, fn %Slice{} = slice, {:ok, acc} ->
      case materialize(environment, slice, opts) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end

  def materialize(environment, ref_or_slice, opts) when is_list(opts) do
    with {:ok, module} <- environment_module(environment, :materialize, 3) do
      module.materialize(environment, ref_or_slice, opts)
    end
  end

  @spec search(term(), EnvironmentRef.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def search(environment, %EnvironmentRef{} = ref, query, opts \\ [])
      when is_binary(query) and is_list(opts) do
    with {:ok, module} <- environment_module(environment, :search, 4) do
      module.search(environment, ref, query, opts)
    end
  end

  @spec plan(atom(), [EnvironmentRef.t()], keyword()) :: {:ok, term()} | {:error, term()}
  def plan(task_kind, source_refs, opts \\ []) when is_list(source_refs) and is_list(opts) do
    Planner.plan(task_kind, source_refs, opts)
  end

  defp environment_module(%module{} = _environment, function, arity) do
    if function_exported?(module, function, arity) do
      {:ok, module}
    else
      {:error,
       Error.validation("RLM environment does not implement #{function}/#{arity}",
         source: __MODULE__,
         details: %{module: module}
       )}
    end
  end
end
