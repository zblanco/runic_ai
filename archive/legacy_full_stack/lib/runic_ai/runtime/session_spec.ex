defmodule RunicAI.Runtime.SessionSpec do
  @moduledoc """
  Configuration for a supervised RunicAI runtime session.

  A session spec describes which recipe should run, which harness driver owns
  the semantic transition, and which runtime backend/scheduler should carry it.
  The canonical state artifact remains `RunicAI.Harness.Session`.
  """

  alias RunicAI.Candidate.Assignment
  alias RunicAI.Candidate.Registry, as: CandidateRegistry
  alias RunicAI.Candidate.SelectionPolicy
  alias RunicAI.Candidate.Spec, as: CandidateSpec
  alias RunicAI.Error
  alias RunicAI.Harness.Integrated
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.TurnProcessor
  alias RunicAI.Runtime.Backends.InMemory
  alias RunicAI.Runtime.Schedulers.Noop

  @valid_kinds [:turn_processor, :integrated]

  @enforce_keys [
    :id,
    :kind,
    :recipe,
    :recipe_opts,
    :driver,
    :backend,
    :backend_opts,
    :scheduler,
    :scheduler_opts,
    :policy,
    :metadata
  ]
  defstruct [
    :id,
    :kind,
    :recipe,
    :driver,
    :candidate_assignment,
    :runner_name,
    :runner_workflow_id,
    recipe_opts: [],
    backend: InMemory,
    backend_opts: [],
    runner_opts: [],
    scheduler: Noop,
    scheduler_opts: [],
    policy: nil,
    metadata: %{}
  ]

  @type backend :: module()
  @type scheduler :: module()

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :turn_processor | :integrated,
          recipe: module(),
          recipe_opts: keyword(),
          driver: module(),
          backend: backend(),
          backend_opts: keyword(),
          runner_name: atom() | nil,
          runner_opts: keyword(),
          runner_workflow_id: term(),
          scheduler: scheduler(),
          scheduler_opts: keyword(),
          policy: Policy.t(),
          candidate_assignment: Assignment.t() | nil,
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, assignment} <- select_candidate(opts),
         {:ok, recipe} <- normalize_recipe(Keyword.get(opts, :recipe), assignment),
         {:ok, recipe_opts} <-
           normalize_recipe_opts(Keyword.get(opts, :recipe_opts, []), assignment),
         {:ok, kind} <- normalize_kind(Keyword.get(opts, :kind), recipe),
         {:ok, driver} <- normalize_driver(Keyword.get(opts, :driver), kind),
         {:ok, backend} <- normalize_backend(Keyword.get(opts, :backend)),
         {:ok, backend_opts} <-
           validate_keyword(Keyword.get(opts, :backend_opts, []), :backend_opts),
         {:ok, runner_opts} <-
           validate_keyword(Keyword.get(opts, :runner_opts, []), :runner_opts),
         {:ok, scheduler} <- normalize_scheduler(Keyword.get(opts, :scheduler)),
         {:ok, scheduler_opts} <-
           validate_keyword(Keyword.get(opts, :scheduler_opts, []), :scheduler_opts),
         {:ok, policy} <- Policy.from_input(Keyword.get(opts, :policy)),
         :ok <- validate_runner_name(Keyword.get(opts, :runner_name)),
         :ok <- validate_map(metadata, :metadata),
         {:ok, id} <- normalize_id(Keyword.get(opts, :id)) do
      metadata = maybe_put_candidate_assignment(metadata, assignment)

      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         recipe: recipe,
         recipe_opts: recipe_opts,
         driver: driver,
         backend: backend,
         backend_opts: backend_opts,
         runner_name: Keyword.get(opts, :runner_name),
         runner_opts: runner_opts,
         runner_workflow_id: Keyword.get(opts, :runner_workflow_id),
         scheduler: scheduler,
         scheduler_opts: scheduler_opts,
         policy: policy,
         candidate_assignment: assignment,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = spec), do: validate(spec)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Runtime.SessionSpec-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    new(
      id: spec.id,
      kind: spec.kind,
      recipe: spec.recipe,
      recipe_opts: spec.recipe_opts,
      driver: spec.driver,
      backend: spec.backend,
      backend_opts: spec.backend_opts,
      runner_name: spec.runner_name,
      runner_opts: spec.runner_opts,
      runner_workflow_id: spec.runner_workflow_id,
      scheduler: spec.scheduler,
      scheduler_opts: spec.scheduler_opts,
      policy: spec.policy,
      candidate: spec.candidate_assignment,
      metadata: spec.metadata
    )
  end

  defp select_candidate(opts) do
    registry_input = Keyword.get(opts, :candidate_registry) || Keyword.get(opts, :candidates)
    explicit_candidate = Keyword.get(opts, :candidate)

    cond do
      match?(%Assignment{}, explicit_candidate) ->
        {:ok, explicit_candidate}

      match?(%CandidateSpec{}, explicit_candidate) ->
        {:ok,
         Assignment.new!(
           explicit_candidate.id,
           explicit_candidate,
           reason: :explicit_candidate
         )}

      not is_nil(registry_input) ->
        with {:ok, registry} <- CandidateRegistry.from_input(registry_input),
             {:ok, policy} <- SelectionPolicy.from_input(Keyword.get(opts, :candidate_policy)),
             {:ok, assignment} <-
               SelectionPolicy.select(policy, registry,
                 session_id: Keyword.get(opts, :id),
                 input: Keyword.get(opts, :candidate_input)
               ) do
          {:ok, assignment}
        end

      true ->
        {:ok, nil}
    end
  end

  defp normalize_recipe(nil, %Assignment{candidate: %CandidateSpec{recipe: recipe}}),
    do: {:ok, recipe}

  defp normalize_recipe(recipe, _assignment) when is_atom(recipe) and not is_nil(recipe),
    do: {:ok, recipe}

  defp normalize_recipe(recipe, _assignment) do
    {:error,
     Error.validation("runtime session recipe must be a module",
       source: __MODULE__,
       details: %{recipe: recipe}
     )}
  end

  defp normalize_recipe_opts(recipe_opts, nil), do: validate_keyword(recipe_opts, :recipe_opts)

  defp normalize_recipe_opts(recipe_opts, %Assignment{candidate: %CandidateSpec{} = candidate}) do
    with {:ok, recipe_opts} <- validate_keyword(recipe_opts, :recipe_opts) do
      {:ok, Keyword.merge(candidate.recipe_opts, recipe_opts)}
    end
  end

  defp normalize_kind(nil, recipe) do
    cond do
      module_exports?(recipe, :initial_runtime, 1) -> {:ok, :integrated}
      true -> {:ok, :turn_processor}
    end
  end

  defp normalize_kind(kind, _recipe) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind, _recipe) do
    {:error,
     Error.validation("invalid runtime session kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp normalize_driver(nil, :turn_processor), do: {:ok, TurnProcessor}
  defp normalize_driver(nil, :integrated), do: {:ok, Integrated}
  defp normalize_driver(driver, _kind) when is_atom(driver), do: {:ok, driver}

  defp normalize_driver(driver, _kind) do
    {:error,
     Error.validation("runtime session driver must be a module",
       source: __MODULE__,
       details: %{driver: driver}
     )}
  end

  defp normalize_backend(nil), do: {:ok, InMemory}
  defp normalize_backend(:in_memory), do: {:ok, InMemory}
  defp normalize_backend(:runner_integrated), do: {:ok, RunicAI.Runtime.Backends.RunnerIntegrated}

  defp normalize_backend(:runner_turn_processor),
    do: {:ok, RunicAI.Runtime.Backends.RunnerTurnProcessor}

  defp normalize_backend(backend) when is_atom(backend), do: {:ok, backend}

  defp normalize_scheduler(nil), do: {:ok, Noop}
  defp normalize_scheduler(:noop), do: {:ok, Noop}
  defp normalize_scheduler(:local_timer), do: {:ok, RunicAI.Runtime.Schedulers.LocalTimer}
  defp normalize_scheduler(scheduler) when is_atom(scheduler), do: {:ok, scheduler}

  defp validate_keyword(value, _field) when is_list(value), do: {:ok, value}

  defp validate_keyword(value, field) do
    {:error,
     Error.validation("runtime session #{field} must be a keyword list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_runner_name(nil), do: :ok
  defp validate_runner_name(name) when is_atom(name), do: :ok

  defp validate_runner_name(name) do
    {:error,
     Error.validation("runtime session runner_name must be an atom or nil",
       source: __MODULE__,
       details: %{runner_name: name}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("runtime session #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_id(nil), do: {:ok, "runtime:session:#{System.unique_integer([:positive])}"}
  defp normalize_id(id) when is_binary(id) and id != "", do: {:ok, id}

  defp normalize_id(id) do
    {:error,
     Error.validation("runtime session id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp module_exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp maybe_put_candidate_assignment(metadata, nil), do: metadata

  defp maybe_put_candidate_assignment(metadata, %Assignment{} = assignment) do
    Map.put_new(metadata, :candidate_assignment, assignment)
  end
end
