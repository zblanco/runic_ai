defmodule RunicAI.Workflows.Catalog do
  @moduledoc """
  Versioned workflow-facing contracts for components that may appear in the
  canonical workflow IR.

  The existing RLM component catalog remains authoritative for assistant
  components. Coding proposal kinds are exposed as an explicit domain dialect
  so they can enter the shared IR without pretending that they already lower
  through the general component factory.
  """

  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentCatalog
  alias RunicAI.RLM.ValueContract

  @contract_version 2

  @type contract :: %{
          required(:key) => String.t(),
          required(:version) => pos_integer(),
          required(:ref) => String.t(),
          required(:hash) => String.t(),
          required(:dialect) => :component | :coding,
          required(:execution_shape) => atom(),
          required(:inputs) => %{String.t() => map()},
          required(:outputs) => %{String.t() => map()},
          required(:effects) => [atom()],
          required(:replay) => map()
        }

  @spec resolve(atom() | String.t()) :: {:ok, contract()} | {:error, Error.t()}
  def resolve(key) when is_atom(key), do: resolve(Atom.to_string(key))

  def resolve("runic_ai/" <> rest = key) do
    case String.split(rest, "/", parts: 2) do
      ["coding", kind] -> coding_contract(key, kind)
      [_component] -> component_contract(key)
    end
  end

  def resolve(key) when is_binary(key) do
    normalized = key |> String.trim() |> String.replace("-", "_")

    cond do
      normalized == "" -> unknown_contract(key)
      String.starts_with?(normalized, "coding/") -> resolve("runic_ai/#{normalized}")
      true -> resolve("runic_ai/#{normalized}")
    end
  end

  def resolve(key), do: unknown_contract(key)

  @spec component_key(atom() | String.t()) :: String.t()
  def component_key(type), do: "runic_ai/#{normalize_name(type)}"

  @spec coding_key(atom() | String.t()) :: String.t()
  def coding_key(kind), do: "runic_ai/coding/#{normalize_name(kind)}"

  @spec snapshot() :: map()
  def snapshot do
    component_keys = Enum.map(ComponentCatalog.types(), &component_key/1)
    coding_keys = Enum.map(ProposalNode.allowed_kinds(), &coding_key/1)

    contracts =
      (component_keys ++ coding_keys)
      |> Enum.sort()
      |> Map.new(fn key ->
        {:ok, contract} = resolve(key)
        {key, contract}
      end)

    %{version: @contract_version, contracts: contracts}
  end

  @spec snapshot_hash() :: String.t()
  def snapshot_hash do
    snapshot()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp component_contract("runic_ai/" <> type_name = key) do
    case component_type(type_name) do
      nil ->
        unknown_contract(key)

      type ->
        with {:ok, entry} <- ComponentCatalog.entry(type) do
          contract = %{
            key: key,
            version: @contract_version,
            dialect: :component,
            execution_shape: entry.execution_shape,
            inputs: ports(entry.inputs),
            outputs: ports(entry.outputs),
            effects: component_effects(type, entry.execution_shape),
            replay: component_replay(type, entry.execution_shape)
          }

          {:ok, pin(contract)}
        end
    end
  end

  defp coding_contract(key, kind_name) do
    case coding_kind(kind_name) do
      nil ->
        unknown_contract(key)

      kind ->
        contract = %{
          key: key,
          version: @contract_version,
          dialect: :coding,
          execution_shape: coding_execution_shape(kind),
          inputs: %{
            "context" => port(ValueContract.json_type(:coding_context), "Coding workflow context")
          },
          outputs: %{
            "context" => port(ValueContract.json_type(:coding_context), "Updated coding context")
          },
          effects: coding_effects(kind),
          replay: coding_replay(kind)
        }

        {:ok, pin(contract)}
    end
  end

  defp ports(ports) do
    Map.new(ports, fn {name, schema} ->
      {Atom.to_string(name),
       port(
         ValueContract.json_type(Keyword.get(schema, :type, :any)),
         Keyword.get(schema, :doc),
         Keyword.get(schema, :required, true)
       )}
    end)
  end

  defp port(contract, doc, required? \\ true) do
    %{
      contract: contract,
      required: required?,
      cardinality: :one,
      mode: :batch,
      doc: doc
    }
  end

  defp pin(contract) do
    ref = "#{contract.key}@#{contract.version}"
    hash_input = :erlang.term_to_binary(contract, [:deterministic])
    hash = :crypto.hash(:sha256, hash_input) |> Base.encode16(case: :lower)
    Map.merge(contract, %{ref: ref, hash: hash})
  end

  defp component_type(name) do
    Enum.find(ComponentCatalog.types(), &(Atom.to_string(&1) == name))
  end

  defp coding_kind(name) do
    Enum.find(ProposalNode.allowed_kinds(), &(Atom.to_string(&1) == name))
  end

  defp component_effects(type, _shape)
       when type in [:llm_map, :record_map, :llm_leaf, :lambda_map],
       do: [:model_call]

  defp component_effects(:artifact_writer, _shape), do: [:workspace_write]
  defp component_effects(:tool_leaf, _shape), do: [:tool_call]
  defp component_effects(:sandbox_execute, _shape), do: [:sandbox_execute]
  defp component_effects(:sandbox_write_file, _shape), do: [:sandbox_write]
  defp component_effects(:workflow_task, _shape), do: [:workflow_invoke]

  defp component_effects(type, _shape)
       when type in [
              :sandbox_open_session,
              :sandbox_session_exec,
              :sandbox_checkpoint,
              :sandbox_restore,
              :sandbox_close_session,
              :sandbox_start_service,
              :sandbox_stop_service,
              :sandbox_open_proxy,
              :sandbox_close_proxy
            ],
       do: [:sandbox_control]

  defp component_effects(_type, _shape), do: []

  defp component_replay(:artifact_writer, _shape) do
    %{
      strategy: :reconcile,
      automatic_retry?: true,
      idempotency_key: [:resolved_path, :content_sha256],
      reconciliation: :compare_existing_content
    }
  end

  defp component_replay(:workflow_task, _shape) do
    %{
      strategy: :durable_invocation,
      automatic_retry?: true,
      idempotency_key: [:parent_run_id, :parent_node_id, :workflow_reference, :input_hash],
      reconciliation: :reuse_recorded_output
    }
  end

  defp component_replay(type, _shape)
       when type in [:llm_map, :record_map, :llm_leaf, :lambda_map] do
    %{
      strategy: :at_least_once,
      automatic_retry?: true,
      consequence: :additional_model_call
    }
  end

  defp component_replay(type, _shape)
       when type in [
              :tool_leaf,
              :sandbox_execute,
              :sandbox_write_file,
              :sandbox_open_session,
              :sandbox_session_exec,
              :sandbox_checkpoint,
              :sandbox_restore,
              :sandbox_close_session,
              :sandbox_start_service,
              :sandbox_stop_service,
              :sandbox_open_proxy,
              :sandbox_close_proxy
            ] do
    %{
      strategy: :manual_reconciliation,
      automatic_retry?: false,
      requirement: :component_specific_idempotency_or_reconciliation
    }
  end

  defp component_replay(_type, _shape),
    do: %{strategy: :safe_replay, automatic_retry?: true}

  defp coding_execution_shape(:reducer), do: :reduce
  defp coding_execution_shape(:review_gate), do: :review
  defp coding_execution_shape(:verification_gate), do: :acceptance
  defp coding_execution_shape(_kind), do: :step

  defp coding_effects(kind) when kind in [:command, :script, :edit, :workflow_patch],
    do: [:workspace_write]

  defp coding_effects(:agent), do: [:child_agent]
  defp coding_effects(:tool), do: [:tool_call]
  defp coding_effects(:llm_leaf), do: [:model_call]
  defp coding_effects(:review_gate), do: [:human_review]
  defp coding_effects(_kind), do: []

  defp coding_replay(:llm_leaf),
    do: %{strategy: :at_least_once, automatic_retry?: true, consequence: :additional_model_call}

  defp coding_replay(:review_gate),
    do: %{strategy: :durable_wait, automatic_retry?: true, reconciliation: :resume_key}

  defp coding_replay(:edit) do
    %{
      strategy: :reconcile_after_unknown,
      automatic_retry?: false,
      reconciliation: :structured_patch_post_state,
      idempotency_key: [:operation, :resolved_path, :expected_hash, :desired_content_hash],
      requirement: :durable_unknown_after_dispatch_context
    }
  end

  defp coding_replay(kind)
       when kind in [:command, :script, :workflow_patch, :tool, :agent] do
    %{
      strategy: :manual_reconciliation,
      automatic_retry?: false,
      requirement: :component_specific_idempotency_or_reconciliation
    }
  end

  defp coding_replay(_kind), do: %{strategy: :safe_replay, automatic_retry?: true}

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_name(value) when is_binary(value) do
    value |> String.trim() |> String.replace("-", "_")
  end

  defp unknown_contract(key) do
    {:error,
     Error.validation("unknown workflow component contract",
       source: __MODULE__,
       details: %{code: :unknown_component_contract, key: key}
     )}
  end
end
