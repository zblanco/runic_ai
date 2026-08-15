defmodule RunicAI.RLM.ComponentFactory do
  @moduledoc """
  Compiles normalized RLM component specs into Runic components.
  """

  require Runic

  alias Runic.Workflow.Step
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentSpec
  alias RunicAI.RLM.ComponentRuntime

  @spec to_runic(ComponentSpec.t(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def to_runic(spec, opts \\ [])

  def to_runic(%ComponentSpec{execution_shape: shape} = spec, _opts)
      when shape not in [:step, :side_effect_step] do
    {:error,
     Error.validation("component execution shape is not step-shaped",
       source: __MODULE__,
       details: %{component_id: spec.id, type: spec.type, execution_shape: shape}
     )}
  end

  def to_runic(%ComponentSpec{} = spec, opts) when is_list(opts) do
    work = Keyword.get(opts, :work, &ComponentRuntime.run/2)

    if is_function(work) do
      {:ok,
       Step.new(
         name: Keyword.get(opts, :name, spec.id),
         hash: Keyword.get(opts, :hash, component_hash(spec)),
         work: work,
         inputs: spec.inputs,
         outputs: spec.outputs,
         meta_refs: context_refs([:component])
       )}
    else
      {:error,
       Error.validation("component work must be a function",
         source: __MODULE__,
         details: %{component_id: spec.id, type: spec.type}
       )}
    end
  end

  @spec to_runic!(ComponentSpec.t(), keyword()) :: struct()
  def to_runic!(%ComponentSpec{} = spec, opts \\ []) do
    case to_runic(spec, opts) do
      {:ok, component} -> component
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec map_items_step(ComponentSpec.t(), keyword()) :: Step.t()
  def map_items_step(%ComponentSpec{} = spec, opts \\ []) when is_list(opts) do
    Step.new(
      name: Keyword.fetch!(opts, :name),
      hash: component_hash({:native_map_items, spec}),
      work: &ComponentRuntime.native_map_items/2,
      inputs: spec.inputs,
      outputs: [items: [type: {:list, :any}, doc: "Items selected for Runic fan-out"]],
      meta_refs: context_refs([:component])
    )
  end

  @spec native_map(ComponentSpec.t(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def native_map(%ComponentSpec{} = spec, opts \\ []) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)

    {:ok,
     Runic.map(
       fn envelope ->
         RunicAI.RLM.ComponentRuntime.native_map_item!(envelope, %{
           workspace: context(:workspace),
           objective: context(:objective),
           sources: context(:sources),
           policies: context(:policies),
           budgets: context(:budgets),
           metadata: context(:metadata),
           event_sink: context(:event_sink),
           opts: context(:opts),
           components_by_id: context(:components_by_id)
         })
       end,
       name: name,
       inputs: [items: [type: :any, cardinality: :many, doc: "Map item envelopes"]],
       outputs: [item: [type: :any, cardinality: :many, doc: "Mapped item facts"]]
     )}
  rescue
    exception ->
      {:error,
       Error.validation("component map shape could not be compiled",
         source: __MODULE__,
         details: %{component_id: spec.id, type: spec.type, error: Exception.message(exception)}
       )}
  end

  @spec native_reduce(ComponentSpec.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, Error.t()}
  def native_reduce(%ComponentSpec{} = spec, map_name, opts \\ []) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)

    {:ok,
     Runic.reduce(
       ComponentRuntime.native_reduce_init(),
       fn item, acc ->
         ComponentRuntime.native_reduce_item(item, acc)
       end,
       name: name,
       map: map_name,
       inputs: [item: [type: :any, cardinality: :many, doc: "Mapped item facts"]],
       outputs: [aggregate: [type: :any, doc: "Reduced aggregate"]]
     )}
  rescue
    exception ->
      {:error,
       Error.validation("component reduce shape could not be compiled",
         source: __MODULE__,
         details: %{component_id: spec.id, type: spec.type, error: Exception.message(exception)}
       )}
  end

  @spec reduce_finalize_step(ComponentSpec.t(), keyword()) :: Step.t()
  def reduce_finalize_step(%ComponentSpec{} = spec, opts \\ []) when is_list(opts) do
    Step.new(
      name: Keyword.fetch!(opts, :name),
      hash: component_hash({:native_reduce_finalize, spec}),
      work: &ComponentRuntime.native_reduce_finalize!/2,
      inputs: [aggregate: [type: :any, doc: "Runic reduce aggregate"]],
      outputs: spec.outputs,
      meta_refs: context_refs([:component])
    )
  end

  @spec input_step(keyword()) :: Step.t()
  def input_step(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, "assistant_input")

    Step.new(
      name: name,
      hash: component_hash({:assistant_input, name}),
      work: &ComponentRuntime.initialize/2,
      outputs: [out: [type: :any, doc: "Initial assistant execution context"]],
      meta_refs: context_refs([:base_context])
    )
  end

  defp context_refs(keys) do
    Enum.map(keys, fn key ->
      %{kind: :context, target: key, context_key: key}
    end)
  end

  defp component_hash(%ComponentSpec{} = spec) do
    :erlang.phash2(
      {__MODULE__, spec.id, spec.type, spec.execution_shape, spec.params, spec.inputs,
       spec.outputs},
      4_294_967_296
    )
  end

  defp component_hash(term), do: :erlang.phash2({__MODULE__, term}, 4_294_967_296)
end
