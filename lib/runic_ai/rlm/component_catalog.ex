defmodule RunicAI.RLM.ComponentCatalog do
  @moduledoc """
  Catalog of RunicAI RLM component types, contracts, and normalization rules.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.ComponentSpec
  alias RunicAI.RLM.ValueContract

  @types [
    :source_discovery,
    :source_splitter,
    :source_materializer,
    :tabular_parser,
    :llm_map,
    :record_map,
    :record_group,
    :document_compare,
    :collection_compute,
    :string_compute,
    :json_compute,
    :artifact_compute,
    :time_compute,
    :score_compute,
    :artifact_materializer,
    :sandbox_status,
    :sandbox_execute,
    :sandbox_open_session,
    :sandbox_session_exec,
    :sandbox_write_file,
    :sandbox_read_file,
    :sandbox_list_files,
    :sandbox_checkpoint,
    :sandbox_restore,
    :sandbox_close_session,
    :sandbox_start_service,
    :sandbox_stop_service,
    :sandbox_list_services,
    :sandbox_open_proxy,
    :sandbox_close_proxy,
    :lambda_plan,
    :lambda_split,
    :lambda_map,
    :lambda_filter,
    :lambda_reduce,
    :lambda_cross,
    :lambda_review,
    :lambda_generate,
    :tool_leaf,
    :llm_leaf,
    :report_composer,
    :blueprint_transform,
    :blueprint_reduce,
    :artifact_writer,
    :objective_scorecard,
    :budget_ledger,
    :verification
  ]

  @type component_type :: atom()

  @spec types() :: [component_type()]
  def types, do: @types

  @spec manifest(keyword()) :: map()
  def manifest(_opts \\ []) do
    %{
      components: Enum.map(@types, &Atom.to_string/1),
      contracts:
        @types
        |> Enum.map(&entry!/1)
        |> Enum.map(fn entry ->
          {Atom.to_string(entry.type),
           %{
             execution_shape: entry.execution_shape,
             inputs: ValueContract.json_ports(entry.inputs),
             outputs: ValueContract.json_ports(entry.outputs)
           }}
        end)
        |> Map.new()
    }
  end

  @spec entry(component_type()) :: {:ok, map()} | {:error, Error.t()}
  def entry(type) when type in @types, do: {:ok, entry!(type)}

  def entry(type) do
    {:error,
     Error.validation("unknown RLM component type",
       source: __MODULE__,
       details: %{code: :unknown_component_type, type: type, valid: @types}
     )}
  end

  @spec spec_from_blueprint(map(), keyword()) :: {:ok, ComponentSpec.t()} | {:error, Error.t()}
  def spec_from_blueprint(component, opts \\ [])

  def spec_from_blueprint(%{id: id, type: type} = component, opts) do
    policy = Map.get(component, :policy, %{})

    with {:ok, entry} <- entry(type),
         {:ok, params} <- normalize_params(type, Map.get(component, :params, %{})),
         {:ok, inputs} <- normalize_ports(Map.get(component, :inputs, []), entry.inputs, :inputs),
         {:ok, outputs} <-
           normalize_ports(Map.get(component, :outputs, ["output"]), entry.outputs, :outputs) do
      {:ok,
       %ComponentSpec{
         id: id,
         type: type,
         execution_shape: execution_shape(entry, type, params, policy),
         params: params,
         inputs: inputs,
         outputs: outputs,
         policy: policy,
         provenance: Map.get(component, :provenance, []),
         metadata: metadata(component, opts),
         blueprint: component
       }}
    end
  end

  def spec_from_blueprint(component, _opts) do
    {:error,
     Error.validation("expected component blueprint data",
       source: __MODULE__,
       details: %{code: :invalid_component_params, component: component}
     )}
  end

  defp entry!(:source_discovery) do
    %{
      type: :source_discovery,
      execution_shape: :step,
      inputs:
        ValueContract.input([:source_request, :assistant_input], "Source discovery request"),
      outputs: ValueContract.output(:source_set, "Discovered workspace sources")
    }
  end

  defp entry!(:source_splitter) do
    %{
      type: :source_splitter,
      execution_shape: :step,
      inputs: ValueContract.input([:source_set, :source_request], "Sources to split"),
      outputs: ValueContract.output(:source_slices, "Source slices")
    }
  end

  defp entry!(:source_materializer) do
    %{
      type: :source_materializer,
      execution_shape: :step,
      inputs: ValueContract.input(:source_slices, "Source slices"),
      outputs: ValueContract.output(:materialized_slices, "Materialized slice contents")
    }
  end

  defp entry!(:tabular_parser) do
    %{
      type: :tabular_parser,
      execution_shape: :step,
      inputs: ValueContract.input([:source_set, :materialized_slices], "Tabular sources"),
      outputs: ValueContract.output(:records, "Parsed records")
    }
  end

  defp entry!(:llm_map) do
    %{
      type: :llm_map,
      execution_shape: :map,
      inputs:
        ValueContract.input(
          [:materialized_slices, :records, :comparisons],
          "Items for LLM mapping"
        ),
      outputs: ValueContract.output(:llm_items, "LLM map outputs")
    }
  end

  defp entry!(:record_map) do
    %{
      type: :record_map,
      execution_shape: :map,
      inputs: ValueContract.input([:records, :record_items], "Records to transform"),
      outputs: ValueContract.output(:record_items, "Record item outputs")
    }
  end

  defp entry!(:record_group) do
    %{
      type: :record_group,
      execution_shape: :step,
      inputs: ValueContract.input([:record_items, :records], "Records or record items"),
      outputs: ValueContract.output(:record_groups, "Grouped record data")
    }
  end

  defp entry!(:document_compare) do
    %{
      type: :document_compare,
      execution_shape: :step,
      inputs: ValueContract.input([:source_set, :materialized_slices], "Documents to compare"),
      outputs: ValueContract.output(:comparisons, "Document comparison results")
    }
  end

  defp entry!(:collection_compute),
    do: computing_entry(:collection_compute, "Collection transform result")

  defp entry!(:string_compute),
    do: computing_entry(:string_compute, "String/text transform result")

  defp entry!(:json_compute), do: computing_entry(:json_compute, "JSON/map transform result")

  defp entry!(:artifact_compute),
    do: computing_entry(:artifact_compute, "Artifact/file metadata result")

  defp entry!(:time_compute), do: computing_entry(:time_compute, "Time/calendar result")
  defp entry!(:score_compute), do: computing_entry(:score_compute, "Scoring/ranking result")

  defp entry!(:artifact_materializer) do
    %{
      type: :artifact_materializer,
      execution_shape: :step,
      inputs: ValueContract.input([:tool_result, :artifact, :computed, :any], "Artifact refs"),
      outputs: ValueContract.output(:materialized_slices, "Bounded artifact previews")
    }
  end

  defp entry!(:sandbox_status) do
    %{
      type: :sandbox_status,
      execution_shape: :side_effect_step,
      inputs: ValueContract.input(:any, "Optional sandbox status selector"),
      outputs: ValueContract.output(:tool_result, "Sandbox backend and capability status")
    }
  end

  defp entry!(:sandbox_execute) do
    %{
      type: :sandbox_execute,
      execution_shape: :side_effect_step,
      inputs: ValueContract.input(:any, "Sandbox code execution input"),
      outputs: ValueContract.output(:tool_result, "Sandbox execution result with diagnostics")
    }
  end

  defp entry!(:lambda_plan) do
    %{
      type: :lambda_plan,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:assistant_input, :source_request, :source_set, :any],
          "Objective and external context refs for Lambda planning"
        ),
      outputs: ValueContract.output(:lambda_plan, "Validated Lambda decomposition plan")
    }
  end

  defp entry!(:lambda_split) do
    %{
      type: :lambda_split,
      execution_shape: :step,
      inputs: ValueContract.input([:lambda_plan, :source_set, :source_request], "Lambda plan"),
      outputs: ValueContract.output(:source_slices, "Bounded Lambda context slices")
    }
  end

  defp entry!(:lambda_map) do
    %{
      type: :lambda_map,
      execution_shape: :map,
      inputs:
        ValueContract.input(
          [:source_slices, :materialized_slices, :records],
          "Lambda leaf inputs"
        ),
      outputs: ValueContract.output(:llm_items, "Lambda leaf outputs")
    }
  end

  defp entry!(:lambda_filter) do
    %{
      type: :lambda_filter,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:source_slices, :records, :llm_items],
          "Lambda items to filter before reduction"
        ),
      outputs: ValueContract.output(:any, "Filtered Lambda items")
    }
  end

  defp entry!(:lambda_reduce) do
    %{
      type: :lambda_reduce,
      execution_shape: :reduce,
      inputs:
        ValueContract.input(
          [:llm_items, :records, :record_items, :record_groups],
          "Lambda outputs to reduce"
        ),
      outputs: ValueContract.output(:synthesis, "Reduced Lambda synthesis")
    }
  end

  defp entry!(:lambda_cross) do
    %{
      type: :lambda_cross,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:source_slices, :materialized_slices, :records, :llm_items],
          "Lambda items to compare pairwise or across sections"
        ),
      outputs: ValueContract.output(:comparisons, "Lambda cross-comparison outputs")
    }
  end

  defp entry!(:lambda_review) do
    %{
      type: :lambda_review,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:llm_items, :records, :record_groups, :synthesis, :report],
          "Lambda intermediate output to review"
        ),
      outputs: ValueContract.output(:scorecard, "Lambda review scorecard")
    }
  end

  defp entry!(:lambda_generate) do
    %{
      type: :lambda_generate,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:scorecard, :synthesis, :record_groups, :llm_items, :comparisons],
          "Reviewed Lambda intermediates"
        ),
      outputs: ValueContract.output(:report, "Generated Lambda final output")
    }
  end

  defp entry!(type)
       when type in [
              :sandbox_open_session,
              :sandbox_session_exec,
              :sandbox_write_file,
              :sandbox_read_file,
              :sandbox_list_files,
              :sandbox_checkpoint,
              :sandbox_restore,
              :sandbox_close_session,
              :sandbox_start_service,
              :sandbox_stop_service,
              :sandbox_list_services,
              :sandbox_open_proxy,
              :sandbox_close_proxy
            ] do
    %{
      type: type,
      execution_shape: :side_effect_step,
      inputs: ValueContract.input(:any, "Sandbox session operation input"),
      outputs: ValueContract.output(:tool_result, "Sandbox session operation result")
    }
  end

  defp entry!(:llm_leaf) do
    %{
      type: :llm_leaf,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [:llm_items, :record_groups, :comparisons, :report, :materialized_slices],
          "Inputs for terminal LLM synthesis"
        ),
      outputs: ValueContract.output(:synthesis, "Synthesized model output")
    }
  end

  defp entry!(:tool_leaf) do
    %{
      type: :tool_leaf,
      execution_shape: :side_effect_step,
      inputs: ValueContract.input(:any, "Inputs available to construct tool arguments"),
      outputs: ValueContract.output(:tool_result, "Tool execution result")
    }
  end

  defp entry!(:report_composer) do
    %{
      type: :report_composer,
      execution_shape: :step,
      inputs:
        ValueContract.input(
          [
            :synthesis,
            :record_groups,
            :comparisons,
            :llm_items,
            :computed,
            :records,
            :source_slices,
            :materialized_slices
          ],
          "Inputs for deterministic report composition"
        ),
      outputs: ValueContract.output(:report, "Composed report")
    }
  end

  defp entry!(:blueprint_transform) do
    %{
      type: :blueprint_transform,
      execution_shape: :step,
      inputs: ValueContract.input(:any, "Value to transform"),
      outputs: ValueContract.output(:any, "Transformed value")
    }
  end

  defp entry!(:blueprint_reduce) do
    %{
      type: :blueprint_reduce,
      execution_shape: :reduce,
      inputs: ValueContract.input(:any, "Values to reduce"),
      outputs: ValueContract.output(:any, "Reduced value")
    }
  end

  defp entry!(:artifact_writer) do
    %{
      type: :artifact_writer,
      execution_shape: :side_effect_step,
      inputs: ValueContract.input([:report, :synthesis, :llm_items], "Artifact content"),
      outputs: ValueContract.output(:artifact, "Written artifact metadata")
    }
  end

  defp entry!(:objective_scorecard) do
    %{
      type: :objective_scorecard,
      execution_shape: :step,
      inputs:
        ValueContract.input([:artifact, :report, :synthesis, :llm_items], "Output to score"),
      outputs: ValueContract.output(:scorecard, "Objective scorecard")
    }
  end

  defp entry!(:budget_ledger) do
    %{
      type: :budget_ledger,
      execution_shape: :step,
      inputs: ValueContract.input(:any, "Budget event or context"),
      outputs: ValueContract.output(:budget_summary, "Budget summary")
    }
  end

  defp entry!(:verification), do: %{entry!(:objective_scorecard) | type: :verification}

  defp computing_entry(type, doc) do
    %{
      type: type,
      execution_shape: :step,
      inputs: ValueContract.input(:any, "Input data for safe deterministic computing"),
      outputs: ValueContract.output(:computed, doc)
    }
  end

  defp normalize_params(:artifact_writer, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_non_empty_string(params, :path),
         :ok <- validate_optional_positive_integer(params, :max_bytes) do
      {:ok, params}
    end
  end

  defp normalize_params(:source_splitter, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :max_bytes),
         :ok <- validate_optional_positive_integer(params, :max_chunks) do
      {:ok, params}
    end
  end

  defp normalize_params(:llm_map, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :max_items),
         :ok <- validate_optional_positive_integer(params, :max_concurrency) do
      {:ok, params}
    end
  end

  defp normalize_params(:record_map, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :max_items),
         :ok <- validate_optional_positive_integer(params, :max_concurrency) do
      {:ok, params}
    end
  end

  defp normalize_params(type, params)
       when type in [
              :collection_compute,
              :string_compute,
              :json_compute,
              :artifact_compute,
              :time_compute,
              :score_compute
            ] do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :limit),
         :ok <- validate_optional_positive_integer(params, :max_bytes),
         :ok <- validate_optional_positive_integer(params, :max_items) do
      {:ok, params}
    end
  end

  defp normalize_params(:sandbox_execute, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :timeout_ms),
         :ok <- validate_optional_positive_integer(params, :max_output_bytes) do
      {:ok, params}
    end
  end

  defp normalize_params(:artifact_materializer, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :max_bytes),
         :ok <- validate_optional_positive_integer(params, :max_artifacts) do
      {:ok, params}
    end
  end

  defp normalize_params(:lambda_plan, params) do
    with {:ok, params} <- ensure_map(params),
         :ok <- validate_optional_positive_integer(params, :leaf_window),
         :ok <- validate_optional_positive_integer(params, :max_depth),
         :ok <- validate_optional_positive_integer(params, :max_leaf_calls),
         :ok <- validate_optional_positive_integer(params, :max_concurrency) do
      {:ok, params}
    end
  end

  defp normalize_params(_type, params), do: ensure_map(params)

  defp normalize_ports([], default, _field), do: {:ok, default}
  defp normalize_ports(["output"], default, :outputs), do: {:ok, default}
  defp normalize_ports([:output], default, :outputs), do: {:ok, default}

  defp normalize_ports([{name, schema} | _] = ports, _default, _field)
       when is_atom(name) and is_list(schema) do
    {:ok, ports}
  end

  defp normalize_ports([first | _] = ports, _default, _field)
       when is_atom(first) or is_binary(first) do
    {:ok,
     Enum.map(ports, fn name ->
       {normalize_port_name(name), ValueContract.port(:any, "Blueprint-declared port")}
     end)}
  end

  defp normalize_ports(ports, _default, field) do
    {:error,
     Error.validation("component #{field} must be a list of port names or port schemas",
       source: __MODULE__,
       details: %{code: :invalid_component_params, field: field, ports: ports}
     )}
  end

  defp ensure_map(params) when is_map(params), do: {:ok, params}

  defp ensure_map(params) do
    {:error,
     Error.validation("component params must be a map",
       source: __MODULE__,
       details: %{code: :invalid_component_params, params: params}
     )}
  end

  defp validate_optional_non_empty_string(params, key) do
    case get(params, key, :missing) do
      :missing ->
        :ok

      value when is_binary(value) ->
        if String.trim(value) == "", do: invalid_string(key, value), else: :ok

      value ->
        invalid_string(key, value)
    end
  end

  defp validate_optional_positive_integer(params, key) do
    case get(params, key, :missing) do
      :missing -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> invalid_positive_integer(key, value)
    end
  end

  defp invalid_string(key, value) do
    {:error,
     Error.validation("component param #{key} must be a non-empty string",
       source: __MODULE__,
       details: %{code: :invalid_component_params, param: key, value: value}
     )}
  end

  defp invalid_positive_integer(key, value) do
    {:error,
     Error.validation("component param #{key} must be a positive integer",
       source: __MODULE__,
       details: %{code: :invalid_component_params, param: key, value: value}
     )}
  end

  defp normalize_port_name(name) when is_atom(name), do: name

  defp normalize_port_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> :out
      "in" -> :in
      "out" -> :out
      "sources" -> :sources
      "records" -> :records
      "items" -> :items
      "report" -> :report
      "artifact" -> :artifact
      _value -> :out
    end
  end

  defp metadata(component, opts) do
    component_metadata = Map.get(component, :metadata, %{}) || %{}

    opts
    |> Keyword.get(:metadata, %{})
    |> Map.merge(component_metadata)
    |> maybe_put(:blueprint_id, Keyword.get(opts, :blueprint_id))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp execution_shape(entry, type, params, policy) do
    requested =
      native_execution_shape(params) ||
        native_execution_shape(policy) ||
        if(native_runic?(params) or native_runic?(policy), do: default_native_shape(type))

    case {type, requested} do
      {type, :map} when type in [:llm_map, :record_map, :blueprint_transform, :lambda_map] ->
        :map

      {:blueprint_reduce, :reduce} ->
        :reduce

      {:lambda_reduce, :reduce} ->
        :reduce

      {:record_group, :reduce} ->
        :reduce

      _other ->
        entry.execution_shape
    end
  end

  defp native_execution_shape(map) when is_map(map) do
    map
    |> get(:execution_shape, nil)
    |> normalize_shape()
  end

  defp native_execution_shape(_map), do: nil

  defp default_native_shape(type)
       when type in [:llm_map, :record_map, :blueprint_transform, :lambda_map],
       do: :map

  defp default_native_shape(type) when type in [:blueprint_reduce, :record_group, :lambda_reduce],
    do: :reduce

  defp default_native_shape(_type), do: nil

  defp native_runic?(map) when is_map(map) do
    get(map, :native_runic?, false) in [true, "true"] or
      get(map, :native_runic, false) in [true, "true"] or
      get(map, :runic_native, false) in [true, "true"]
  end

  defp native_runic?(_map), do: false

  defp normalize_shape(shape) when shape in [:step, :map, :reduce, :rule, :accumulator],
    do: shape

  defp normalize_shape(shape) when is_binary(shape) do
    case String.replace(shape, "-", "_") do
      "step" -> :step
      "map" -> :map
      "reduce" -> :reduce
      "rule" -> :rule
      "accumulator" -> :accumulator
      _other -> nil
    end
  end

  defp normalize_shape(_shape), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
end
