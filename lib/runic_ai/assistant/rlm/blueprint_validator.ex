defmodule RunicAI.Assistant.RLM.BlueprintValidator do
  @moduledoc """
  Validator for generated assistant workflow blueprints.

  The validator returns a structured report so the assistant can reason about
  failures and repair the graph without relying on exception strings.
  """

  alias RunicAI.Assistant.RLM.BlueprintGraph
  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentCatalog

  @default_max_nodes 20

  @type diagnostic :: %{
          required(:severity) => :error | :warning,
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:details) => map()
        }

  @type report :: %{
          required(:status) => :accepted | :rejected,
          required(:diagnostics) => [diagnostic()],
          required(:blueprint_id) => String.t() | nil
        }

  @spec report(WorkflowBlueprint.t() | map(), keyword()) :: report()
  def report(blueprint_input, opts \\ []) when is_list(opts) do
    case WorkflowBlueprint.from_input(blueprint_input) do
      {:ok, blueprint} ->
        diagnostics =
          []
          |> check_components_present(blueprint)
          |> check_stop_conditions(blueprint)
          |> check_unique_ids(blueprint)
          |> check_catalog(blueprint)
          |> check_graph(blueprint)
          |> check_budgets(blueprint, opts)
          |> check_function_policies(blueprint, opts)
          |> check_artifact_writers(blueprint)

        %{
          status:
            if(Enum.any?(diagnostics, &(&1.severity == :error)), do: :rejected, else: :accepted),
          diagnostics: Enum.reverse(diagnostics),
          blueprint_id: blueprint.id
        }

      {:error, %Error{} = error} ->
        %{
          status: :rejected,
          diagnostics: [
            diagnostic(:error, :invalid_contract, error.message, %{error: error})
          ],
          blueprint_id: nil
        }
    end
  end

  @spec validate(WorkflowBlueprint.t() | map(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def validate(blueprint_input, opts \\ []) when is_list(opts) do
    report = report(blueprint_input, opts)

    if accepted?(report) do
      {:ok, report}
    else
      {:error,
       Error.validation("assistant workflow blueprint rejected",
         source: __MODULE__,
         details: %{report: report}
       )}
    end
  end

  @spec accepted?(report()) :: boolean()
  def accepted?(%{status: :accepted}), do: true
  def accepted?(_report), do: false

  defp check_components_present(diagnostics, %WorkflowBlueprint{components: []}) do
    [
      diagnostic(:error, :missing_components, "workflow blueprint must include components")
      | diagnostics
    ]
  end

  defp check_components_present(diagnostics, _blueprint), do: diagnostics

  defp check_stop_conditions(diagnostics, %WorkflowBlueprint{stop_conditions: []}) do
    [
      diagnostic(:error, :missing_stop_conditions, "workflow blueprint needs stop conditions")
      | diagnostics
    ]
  end

  defp check_stop_conditions(diagnostics, _blueprint), do: diagnostics

  defp check_unique_ids(diagnostics, %WorkflowBlueprint{} = blueprint) do
    ids = WorkflowBlueprint.component_ids(blueprint)
    duplicates = ids -- Enum.uniq(ids)

    if duplicates == [] do
      diagnostics
    else
      [
        diagnostic(:error, :duplicate_component_ids, "component ids must be unique", %{
          duplicates: Enum.uniq(duplicates)
        })
        | diagnostics
      ]
    end
  end

  defp check_catalog(diagnostics, %WorkflowBlueprint{} = blueprint) do
    Enum.reduce(blueprint.components, diagnostics, fn component, diagnostics ->
      case ComponentCatalog.spec_from_blueprint(component, blueprint_id: blueprint.id) do
        {:ok, _spec} ->
          diagnostics

        {:error, %Error{} = error} ->
          [
            diagnostic(:error, error_code(error, :invalid_component_params), error.message, %{
              component_id: component.id,
              error: error
            })
            | diagnostics
          ]
      end
    end)
  end

  defp check_graph(diagnostics, %WorkflowBlueprint{} = blueprint) do
    graph_diagnostics =
      blueprint
      |> BlueprintGraph.diagnostics()
      |> Enum.reject(
        &(&1.code in [
            :duplicate_component_ids,
            :invalid_component_params,
            :unknown_component_type
          ])
      )

    Enum.reduce(graph_diagnostics, diagnostics, &[&1 | &2])
  end

  defp check_budgets(diagnostics, %WorkflowBlueprint{} = blueprint, opts) do
    max_nodes =
      opts[:max_nodes] ||
        get_in(blueprint.policies, [:budgets, :max_nodes]) ||
        get_in(blueprint.policies, ["budgets", "max_nodes"]) ||
        @default_max_nodes

    if length(blueprint.components) > max_nodes do
      [
        diagnostic(:error, :node_budget_exceeded, "workflow blueprint exceeds max node budget", %{
          max_nodes: max_nodes,
          node_count: length(blueprint.components)
        })
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp check_function_policies(diagnostics, %WorkflowBlueprint{} = blueprint, opts) do
    max_tier = max_generated_function_tier(blueprint, opts)

    Enum.reduce(blueprint.components, diagnostics, fn component, diagnostics ->
      function = component.params[:function] || component.params["function"]

      cond do
        is_nil(function) ->
          diagnostics

        true ->
          case FunctionBlueprint.from_input(function) do
            {:ok, blueprint} ->
              if FunctionBlueprint.tier_rank(blueprint.tier) <=
                   FunctionBlueprint.tier_rank(max_tier) do
                diagnostics
              else
                [
                  diagnostic(
                    :error,
                    :function_tier_rejected,
                    "function blueprint tier exceeds workflow policy",
                    %{component_id: component.id, tier: blueprint.tier, max_tier: max_tier}
                  )
                  | diagnostics
                ]
              end

            {:error, %Error{} = error} ->
              [
                diagnostic(:error, :invalid_function_blueprint, error.message, %{
                  component_id: component.id,
                  error: error
                })
                | diagnostics
              ]
          end
      end
    end)
  end

  defp check_artifact_writers(diagnostics, %WorkflowBlueprint{} = blueprint) do
    Enum.reduce(blueprint.components, diagnostics, fn
      %{id: id, type: :artifact_writer, params: params}, diagnostics ->
        path = params[:path] || params["path"]

        if is_binary(path) and String.trim(path) != "" do
          diagnostics
        else
          [
            diagnostic(
              :error,
              :invalid_artifact_writer_path,
              "artifact_writer components require a non-empty path",
              %{component_id: id, path: path}
            )
            | diagnostics
          ]
        end

      _component, diagnostics ->
        diagnostics
    end)
  end

  defp max_generated_function_tier(%WorkflowBlueprint{} = blueprint, opts) do
    tier =
      opts[:max_generated_function_tier] ||
        get_in(blueprint.policies, [:generated_functions, :max_tier]) ||
        get_in(blueprint.policies, ["generated_functions", "max_tier"]) ||
        :tier1

    normalize_max_tier(tier)
  end

  defp normalize_max_tier(tier) when tier in [:tier0, :tier1, :tier2], do: tier
  defp normalize_max_tier("tier0"), do: :tier0
  defp normalize_max_tier("tier1"), do: :tier1
  defp normalize_max_tier("tier2"), do: :tier2
  defp normalize_max_tier(_tier), do: :tier1

  defp error_code(%Error{details: details}, default) when is_map(details),
    do: Map.get(details, :code, default)

  defp error_code(_error, default), do: default

  defp diagnostic(severity, code, message, details \\ %{}) do
    %{severity: severity, code: code, message: message, details: details}
  end
end
