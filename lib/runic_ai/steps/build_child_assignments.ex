defmodule RunicAI.Steps.BuildChildAssignments do
  @moduledoc """
  Materialize a `RunicAI.Decomposition.TaskPlan` into child assignments with
  scoped context, tool, and policy inheritance.
  """

  require Runic

  alias RunicAI.Agent.State
  alias RunicAI.Context.Bundle
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Context.WindowPolicy
  alias RunicAI.Control.BudgetPolicy
  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.InheritancePolicy
  alias RunicAI.Decomposition.Registry, as: DecompositionRegistry
  alias RunicAI.Decomposition.Role
  alias RunicAI.Decomposition.Task
  alias RunicAI.Decomposition.TaskPlan
  alias RunicAI.Steps.BuildHandoff
  alias RunicAI.Tool.Registry, as: ToolRegistry
  alias RunicAI.Tool.Selection

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :build_child_assignments)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        build!(input, defaults)
      end,
      name: name
    )
  end

  @spec build(TaskPlan.t() | map(), keyword()) ::
          {:ok, [Assignment.t()]} | {:error, RunicAI.Error.t()}
  def build(input, opts \\ [])

  def build(%TaskPlan{} = task_plan, opts) when is_list(opts) do
    build(%{task_plan: task_plan}, opts)
  end

  def build(input, opts) when is_map(input) and is_list(opts) do
    with {:ok, task_plan} <- resolve_task_plan(input, opts),
         {:ok, registry} <- resolve_role_registry(input, opts),
         {:ok, parent_state} <- resolve_parent_state(input, opts),
         {:ok, parent_selection} <- resolve_parent_selection(input, opts),
         {:ok, budget_policy} <- resolve_budget_policy(input, opts),
         {:ok, window_policy} <- resolve_window_policy(input, opts) do
      task_plan.tasks
      |> Enum.reduce_while({:ok, []}, fn %Task{} = task, {:ok, acc} ->
        case build_assignment(
               task,
               registry,
               parent_state,
               parent_selection,
               budget_policy,
               window_policy,
               input,
               opts
             ) do
          {:ok, assignment} -> {:cont, {:ok, [assignment | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
        error -> error
      end
    end
  end

  @spec build!(TaskPlan.t() | map(), keyword()) :: [Assignment.t()]
  def build!(input, opts \\ []) do
    case build(input, opts) do
      {:ok, assignments} -> assignments
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp build_assignment(
         %Task{} = task,
         %DecompositionRegistry{} = registry,
         parent_state,
         parent_selection,
         budget_policy,
         window_policy,
         parent_input,
         opts
       ) do
    with {:ok, role} <- resolve_role(task, registry),
         {:ok, inheritance} <- resolve_inheritance(task, role, parent_input, opts),
         {:ok, context_projection} <- build_context_projection(task, parent_state, inheritance),
         {:ok, tool_projection} <- build_tool_projection(parent_selection, inheritance),
         {:ok, budget_projection} <- build_budget_projection(budget_policy, inheritance),
         {:ok, input} <-
           build_assignment_input(
             task,
             role,
             inheritance,
             context_projection,
             tool_projection,
             budget_projection,
             window_policy,
             parent_input
           ),
         {:ok, seed_state} <- build_seed_state(task, role, context_projection),
         {:ok, metadata} <-
           build_assignment_metadata(task, role, inheritance, context_projection, tool_projection),
         {:ok, assignment} <-
           Assignment.new(task, role,
             id: "assignment:#{task.id}",
             inheritance: inheritance,
             input: input,
             seed_state: seed_state,
             resume_key: "child:#{task.id}",
             metadata: metadata
           ) do
      {:ok, assignment}
    end
  end

  defp resolve_task_plan(input, opts) do
    TaskPlan.from_input(
      Map.get(input, :task_plan) || Map.get(input, "task_plan"),
      groups: Keyword.get(opts, :groups),
      join_policy: Keyword.get(opts, :join_policy),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp resolve_role_registry(input, opts) do
    input
    |> Map.get(:registry, Map.get(input, "registry"))
    |> Kernel.||(Map.get(input, :role_registry) || Map.get(input, "role_registry"))
    |> Kernel.||(Keyword.get(opts, :registry) || Keyword.get(opts, :role_registry))
    |> DecompositionRegistry.from_input()
  end

  defp resolve_parent_state(input, opts) do
    case Map.get(input, :state) || Map.get(input, "state") || Keyword.get(opts, :state) do
      nil -> {:ok, nil}
      %State{} = state -> State.validate(state)
      other -> invalid_value("child assignment parent state", other)
    end
  end

  defp resolve_parent_selection(input, opts) do
    explicit =
      Map.get(input, :selection) ||
        Map.get(input, "selection") ||
        Map.get(input, :tool_selection) ||
        Map.get(input, "tool_selection") ||
        Keyword.get(opts, :selection) ||
        Keyword.get(opts, :tool_selection)

    cond do
      match?(%Selection{}, explicit) ->
        Selection.validate(explicit)

      true ->
        registry =
          Map.get(input, :tool_registry) ||
            Map.get(input, "tool_registry") ||
            Map.get(input, :visible_registry) ||
            Map.get(input, "visible_registry") ||
            Keyword.get(opts, :tool_registry) ||
            Keyword.get(opts, :visible_registry)

        visible_tools =
          Map.get(input, :visible_tools) ||
            Map.get(input, "visible_tools") ||
            Keyword.get(opts, :visible_tools)

        with {:ok, registry} <- resolve_tool_registry(registry),
             {:ok, selection} <- build_selection(registry, visible_tools) do
          {:ok, selection}
        end
    end
  end

  defp resolve_tool_registry(nil), do: {:ok, nil}

  defp resolve_tool_registry(%ToolRegistry{} = registry) do
    ToolRegistry.validate(registry)
  end

  defp resolve_tool_registry(other) when is_list(other) do
    ToolRegistry.from_input(other)
  end

  defp resolve_tool_registry(other), do: invalid_value("child assignment tool registry", other)

  defp build_selection(nil, _visible_tools), do: {:ok, nil}

  defp build_selection(%ToolRegistry{} = registry, nil) do
    Selection.new(registry, registry.tools)
  end

  defp build_selection(%ToolRegistry{} = registry, visible_tools) do
    Selection.new(registry, visible_tools)
  end

  defp resolve_budget_policy(input, opts) do
    input
    |> Map.get(:budget_policy, Map.get(input, "budget_policy"))
    |> Kernel.||(Keyword.get(opts, :budget_policy))
    |> BudgetPolicy.from_input()
  end

  defp resolve_window_policy(input, opts) do
    case Map.get(input, :window_policy) || Map.get(input, "window_policy") ||
           Keyword.get(opts, :window_policy) do
      nil -> {:ok, nil}
      %WindowPolicy{} = policy -> WindowPolicy.validate(policy)
      other -> invalid_value("child assignment window policy", other)
    end
  end

  defp resolve_role(%Task{role: %Role{} = role}, _registry), do: Role.validate(role)

  defp resolve_role(%Task{role: role_name}, %DecompositionRegistry{} = registry),
    do: DecompositionRegistry.fetch(registry, role_name)

  defp resolve_inheritance(%Task{} = task, %Role{} = role, input, opts) do
    task_policy =
      metadata_get(task.metadata, :inheritance_policy) ||
        metadata_get(task.metadata, :inheritance)

    role_policy =
      Map.get(role.defaults, :inheritance_policy) ||
        Map.get(role.defaults, "inheritance_policy") ||
        Map.get(role.defaults, :inheritance)

    parent_policy =
      Map.get(input, :inheritance_policy) ||
        Map.get(input, "inheritance_policy") ||
        Keyword.get(opts, :inheritance_policy)

    InheritancePolicy.from_input(task_policy || role_policy || parent_policy)
  end

  defp build_context_projection(%Task{} = task, _state, %InheritancePolicy{} = inheritance)
       when not is_nil(task.handoff) do
    {:ok,
     %{
       handoff: task.handoff,
       context_bundle: nil,
       context_refs: Enum.take(task.handoff.references, inheritance.max_context_refs),
       context_mode: :handoff
     }}
  end

  defp build_context_projection(%Task{} = task, _state, %InheritancePolicy{} = inheritance)
       when not is_nil(task.context_bundle) do
    {:ok,
     %{
       handoff: nil,
       context_bundle: task.context_bundle,
       context_refs: Enum.take(task.context_bundle.refs, inheritance.max_context_refs),
       context_mode: :bundle
     }}
  end

  defp build_context_projection(_task, nil, %InheritancePolicy{} = inheritance) do
    {:ok,
     %{
       handoff: nil,
       context_bundle: nil,
       context_refs: [],
       context_mode: inheritance.context_mode
     }}
  end

  defp build_context_projection(
         %Task{} = task,
         %State{} = state,
         %InheritancePolicy{} = inheritance
       ) do
    case inheritance.context_mode do
      :handoff ->
        handoff =
          state
          |> BuildHandoff.build!(task.goal, include_refs?: inheritance.max_context_refs > 0)
          |> limit_handoff_refs(inheritance.max_context_refs)

        {:ok,
         %{
           handoff: handoff,
           context_bundle: nil,
           context_refs: handoff.references,
           context_mode: :handoff
         }}

      :bundle ->
        bundle = build_bundle_from_state(state, inheritance.max_context_refs)

        {:ok,
         %{
           handoff: nil,
           context_bundle: bundle,
           context_refs: bundle.refs,
           context_mode: :bundle
         }}

      :refs ->
        refs = collect_refs(state, inheritance.max_context_refs)

        {:ok,
         %{
           handoff: nil,
           context_bundle: nil,
           context_refs: refs,
           context_mode: :refs
         }}

      :none ->
        {:ok,
         %{
           handoff: nil,
           context_bundle: nil,
           context_refs: [],
           context_mode: :none
         }}
    end
  end

  defp build_tool_projection(nil, %InheritancePolicy{tool_mode: :none}) do
    {:ok, %{selection: nil, visible_tools: [], registry: nil}}
  end

  defp build_tool_projection(nil, _inheritance) do
    {:ok, %{selection: nil, visible_tools: [], registry: nil}}
  end

  defp build_tool_projection(%Selection{} = selection, %InheritancePolicy{} = inheritance) do
    tool_names =
      case inheritance.tool_mode do
        :none ->
          []

        :inherit ->
          restrict_tool_names(Selection.visible_names(selection), inheritance.allowed_tools)

        :subset ->
          restrict_tool_names(Selection.visible_names(selection), inheritance.allowed_tools)

        :override ->
          restrict_tool_names(ToolRegistry.names(selection.registry), inheritance.allowed_tools)
      end

    case tool_names do
      [] ->
        {:ok, %{selection: nil, visible_tools: [], registry: selection.registry}}

      _ ->
        with {:ok, child_selection} <- Selection.new(selection.registry, tool_names) do
          {:ok,
           %{
             selection: child_selection,
             visible_tools: child_selection.visible_tools,
             registry: child_selection.registry
           }}
        end
    end
  end

  defp build_budget_projection(nil, _inheritance), do: {:ok, nil}

  defp build_budget_projection(
         %BudgetPolicy{} = parent_budget,
         %InheritancePolicy{} = inheritance
       ) do
    case inheritance.budget_mode do
      :none ->
        {:ok, nil}

      :copy ->
        {:ok, parent_budget}

      :slice ->
        merge_budget(parent_budget, inheritance.budget_overrides)

      :fresh ->
        case map_size(inheritance.budget_overrides) do
          0 -> {:ok, nil}
          _ -> BudgetPolicy.from_input(inheritance.budget_overrides)
        end
    end
  end

  defp build_assignment_input(
         %Task{} = task,
         %Role{} = role,
         %InheritancePolicy{} = inheritance,
         context_projection,
         tool_projection,
         budget_projection,
         window_policy,
         parent_input
       ) do
    metadata =
      %{
        task_id: task.id,
        role: role.name,
        parent_goal: Map.get(parent_input, :goal) || Map.get(parent_input, "goal")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(task.metadata)

    {:ok,
     %{
       task_id: task.id,
       assignment_id: "assignment:#{task.id}",
       role: role.name,
       role_kind: role.kind,
       goal: task.goal,
       instructions: task.instructions,
       input: task.input,
       output_contract: task.output_contract,
       handoff: context_projection.handoff,
       context_bundle: context_projection.context_bundle,
       context_refs: context_projection.context_refs,
       tool_selection: tool_projection.selection,
       visible_tools: tool_projection.visible_tools,
       tool_registry: tool_projection.registry,
       budget_policy: budget_projection,
       window_policy: window_policy,
       memory_scope:
         inheritance.memory_scope || Map.get(parent_input, :memory_scope) ||
           Map.get(parent_input, "memory_scope"),
       metadata: metadata
     }}
  end

  defp build_seed_state(%Task{} = _task, %Role{} = _role, %{handoff: %HandoffArtifact{} = handoff}) do
    {:ok,
     State.new!(
       messages: handoff.seed_messages,
       metadata: %{
         source: :child_handoff_seed,
         handoff_goal: handoff.brief
       }
     )}
  end

  defp build_seed_state(%Task{} = _task, %Role{} = _role, %{context_bundle: %Bundle{} = bundle}) do
    {:ok,
     State.new!(
       messages: bundle.messages,
       metadata: %{
         source: :child_context_bundle_seed,
         token_estimate: bundle.token_estimate
       }
     )}
  end

  defp build_seed_state(_task, _role, _context_projection), do: {:ok, nil}

  defp build_assignment_metadata(
         %Task{} = task,
         %Role{} = role,
         %InheritancePolicy{} = inheritance,
         context_projection,
         tool_projection
       ) do
    {:ok,
     %{
       task_id: task.id,
       role: role.name,
       context_mode: context_projection.context_mode,
       inherited_tool_names: Enum.map(tool_projection.visible_tools, & &1.name),
       depends_on: task.depends_on,
       inheritance: inheritance
     }}
  end

  defp merge_budget(%BudgetPolicy{} = policy, overrides) when is_map(overrides) do
    policy
    |> Map.from_struct()
    |> Map.drop([:__struct__])
    |> Map.merge(overrides)
    |> BudgetPolicy.from_input()
  end

  defp build_bundle_from_state(%State{} = state, max_context_refs) do
    refs = collect_refs(state, max_context_refs)
    messages = bundle_messages(state)

    Bundle.new!(
      messages: messages,
      refs: refs,
      focus: state.context && state.context.last_focus,
      coverage: %{source: :child_assignment}
    )
  end

  defp bundle_messages(%State{} = state) do
    messages = state.conversation.messages
    {system_prefix, rest} = Enum.split_while(messages, &(&1.role == :system))
    system_prefix ++ Enum.take(rest, -6)
  end

  defp collect_refs(%State{context: nil}, _max_context_refs), do: []

  defp collect_refs(%State{} = state, max_context_refs) do
    state.context.active_refs
    |> Kernel.++(state.context.tail_refs)
    |> Enum.uniq_by(&{&1.kind, &1.target_id})
    |> Enum.take(max_context_refs)
  end

  defp limit_handoff_refs(%HandoffArtifact{} = handoff, max_context_refs) do
    %{handoff | references: Enum.take(handoff.references, max_context_refs)}
  end

  defp restrict_tool_names(tool_names, []), do: tool_names

  defp restrict_tool_names(tool_names, allowed_tools),
    do: Enum.filter(tool_names, &(&1 in allowed_tools))

  defp metadata_get(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_get(_metadata, _key), do: nil

  defp invalid_value(label, value) do
    {:error,
     RunicAI.Error.validation("#{label} must be a recognized RunicAI value",
       source: __MODULE__,
       details: %{value: value}
     )}
  end
end
