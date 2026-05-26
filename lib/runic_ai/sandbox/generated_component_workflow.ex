defmodule RunicAI.Sandbox.GeneratedComponentWorkflow do
  @moduledoc """
  Composes verified sandbox-generated components into assistant workflow blueprints.

  This module is deliberately data-only. It does not execute generated code,
  write artifacts, or grant host access. It turns already-verified
  `RunicAI.Sandbox.GeneratedComponent` contracts into ordinary
  `:sandbox_execute` assistant components so the existing coordinator,
  capability-profile validation, review gates, and trace machinery can handle
  execution.
  """

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent

  @default_scorecard_id "verify_generated_components"

  @spec compose(String.t(), GeneratedComponent.t() | map() | keyword() | [term()], keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def compose(objective, components_input, opts \\ [])

  def compose(objective, components_input, opts)
      when is_binary(objective) and objective != "" and is_list(opts) do
    with {:ok, components} <- normalize_components(components_input),
         :ok <- validate_option_maps(opts),
         {:ok, component_blueprints} <- component_blueprints(components, opts),
         {:ok, scorecard} <- scorecard_component(opts),
         {:ok, blueprint} <-
           WorkflowBlueprint.new(objective, component_blueprints ++ [scorecard],
             id: Keyword.get(opts, :id, default_blueprint_id()),
             sources: Keyword.get(opts, :sources, []),
             edges: edges(component_blueprints, scorecard, opts),
             stop_conditions: stop_conditions(opts),
             policies: workflow_policies(components, opts),
             metadata: workflow_metadata(components, opts)
           ),
         {:ok, blueprint} <- maybe_validate(blueprint, opts) do
      {:ok, blueprint}
    end
  end

  def compose(objective, _components_input, _opts) do
    {:error,
     Error.validation("generated component workflow objective must be a non-empty string",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  defp validate_option_maps(opts) do
    [
      component_params: Keyword.get(opts, :component_params, %{}),
      component_policy: Keyword.get(opts, :component_policy, %{}),
      policies: Keyword.get(opts, :policies, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      scorecard_params: Keyword.get(opts, :scorecard_params, %{})
    ]
    |> Enum.find(fn {_field, value} -> not is_map(value) end)
    |> case do
      nil ->
        :ok

      {field, value} ->
        {:error,
         Error.validation("generated component workflow option must be a map",
           source: __MODULE__,
           details: %{field: field, value: value}
         )}
    end
  end

  defp normalize_components(%GeneratedComponent{} = component), do: {:ok, [component]}

  defp normalize_components(input) when is_list(input) do
    if Keyword.keyword?(input) do
      input
      |> GeneratedComponent.from_input()
      |> wrap_component()
    else
      input
      |> Enum.reduce_while({:ok, []}, fn component_input, {:ok, acc} ->
        case GeneratedComponent.from_input(component_input) do
          {:ok, component} -> {:cont, {:ok, [component | acc]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, []} -> empty_components_error()
        {:ok, components} -> {:ok, Enum.reverse(components)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp normalize_components(input) when is_map(input) do
    input
    |> GeneratedComponent.from_input()
    |> wrap_component()
  end

  defp normalize_components(input) do
    {:error,
     Error.validation("generated component workflow requires generated component input",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  defp wrap_component({:ok, component}), do: {:ok, [component]}
  defp wrap_component({:error, %Error{} = error}), do: {:error, error}

  defp empty_components_error do
    {:error,
     Error.validation("generated component workflow requires at least one component",
       source: __MODULE__
     )}
  end

  defp component_blueprints(components, opts) do
    components
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {component, index}, {:ok, acc} ->
      case component_blueprint(component, index, opts) do
        {:ok, blueprint} -> {:cont, {:ok, [blueprint | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, blueprints} -> {:ok, Enum.reverse(blueprints)}
      {:error, error} -> {:error, error}
    end
  end

  defp component_blueprint(%GeneratedComponent{} = component, index, opts) do
    GeneratedComponent.to_component_blueprint(component,
      id: component_id(component, index, opts),
      inputs: component_ports(component, :inputs, ["input"]),
      outputs: component_ports(component, :outputs, ["output"]),
      params: component_params(opts),
      policy: component_policy(opts)
    )
  end

  defp component_id(%GeneratedComponent{} = component, index, opts) do
    case Keyword.get(opts, :component_ids) do
      ids when is_list(ids) ->
        Enum.at(ids, index - 1) || component.id

      ids when is_map(ids) ->
        Map.get(ids, component.id, Map.get(ids, Integer.to_string(index), component.id))

      _other ->
        component.id
    end
  end

  defp component_ports(%GeneratedComponent{interface: interface}, key, default) do
    interface
    |> interface_ports(key)
    |> case do
      [] -> default
      ports -> ports
    end
  end

  defp interface_ports(interface, key) when is_map(interface) do
    case get(interface, key, []) do
      ports when is_list(ports) ->
        ports
        |> Enum.map(&port_name/1)
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp interface_ports(_interface, _key), do: []

  defp port_name(name) when is_binary(name) and name != "", do: name
  defp port_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp port_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp port_name(_port), do: nil

  defp component_params(opts) do
    Keyword.get(opts, :component_params, %{})
  end

  defp component_policy(opts) do
    %{
      generated_component: %{require_verified?: true},
      sandbox: %{network: :disabled}
    }
    |> Map.merge(Keyword.get(opts, :component_policy, %{}))
  end

  defp scorecard_component(opts) do
    ComponentBlueprint.new(scorecard_id(opts), :objective_scorecard,
      params: Keyword.get(opts, :scorecard_params, %{})
    )
  end

  defp scorecard_id(opts), do: Keyword.get(opts, :scorecard_id, @default_scorecard_id)

  defp edges([], _scorecard, _opts), do: []

  defp edges(component_blueprints, scorecard, opts) do
    case Keyword.get(opts, :edge_strategy, :chain) do
      :fan_in ->
        Enum.map(component_blueprints, &%{from: &1.id, to: scorecard.id})

      "fan_in" ->
        Enum.map(component_blueprints, &%{from: &1.id, to: scorecard.id})

      _chain ->
        component_blueprints
        |> Enum.map(& &1.id)
        |> chain_edges(scorecard.id)
    end
  end

  defp chain_edges([only], scorecard_id), do: [%{from: only, to: scorecard_id}]

  defp chain_edges(ids, scorecard_id) do
    ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> %{from: from, to: to} end)
    |> Kernel.++([%{from: List.last(ids), to: scorecard_id}])
  end

  defp stop_conditions(opts) do
    Keyword.get(opts, :stop_conditions, [
      "generated component execution completed",
      "objective scorecard satisfied"
    ])
  end

  defp workflow_policies(components, opts) do
    %{
      generated_components: %{
        require_verified?: true,
        require_source_artifacts?: true,
        component_count: length(components)
      },
      sandbox: %{network: :disabled},
      budgets: %{max_nodes: length(components) + 1}
    }
    |> Map.merge(Keyword.get(opts, :policies, %{}))
  end

  defp workflow_metadata(components, opts) do
    %{
      proposal_kind: :generated_component_composition,
      composed_by: inspect(__MODULE__),
      generated_component_ids: Enum.map(components, & &1.id)
    }
    |> Map.merge(Keyword.get(opts, :metadata, %{}))
  end

  defp maybe_validate(%WorkflowBlueprint{} = blueprint, opts) do
    if Keyword.get(opts, :validate?, true) do
      case BlueprintValidator.validate(blueprint, validation_opts(opts)) do
        {:ok, _report} -> {:ok, blueprint}
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:ok, blueprint}
    end
  end

  defp validation_opts(opts) do
    Keyword.take(opts, [
      :profile,
      :toolsets,
      :disabled_tools,
      :max_generated_function_tier,
      :max_nodes,
      :sandbox_session_registry
    ])
  end

  defp default_blueprint_id do
    "generated_component_workflow:#{System.unique_integer([:positive])}"
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
