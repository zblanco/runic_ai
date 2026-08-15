defmodule RunicAI.Workflows.SubstrateEval do
  @moduledoc """
  Deterministic substrate bake-off for canonical JSON, compact DSL, and typed operations.

  Provider-reported usage can be attached per arm. Serialized bytes are retained
  for reproducibility and are not presented as token estimates.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.DSL
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR

  @arms [:normalized_json, :compact_dsl, :typed_operations]

  @spec run_case(String.t(), IR.t() | map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_case(case_id, target_input, opts \\ []) when is_binary(case_id) and is_list(opts) do
    with {:ok, target} <- IR.from_input(target_input) do
      target_hash = IR.semantic_hash(target)

      rows = [
        json_arm(case_id, target, target_hash, opts),
        dsl_arm(case_id, target, target_hash, opts),
        operations_arm(case_id, target_hash, opts)
      ]

      {:ok,
       %{
         case_id: case_id,
         target_hash: target_hash,
         rows: rows,
         all_pass?: Enum.all?(rows, &(&1.status == :pass)),
         provider_usage_complete?:
           Enum.all?(rows, &(not is_nil(get_in(&1, [:metrics, :provider_usage]))))
       }}
    end
  end

  @spec arms() :: [atom()]
  def arms, do: @arms

  defp json_arm(case_id, target, target_hash, opts) do
    started = System.monotonic_time(:microsecond)
    source = Jason.encode!(target)

    result =
      with {:ok, decoded} <- Jason.decode(source),
           {:ok, parsed} <- IR.from_input(decoded) do
        semantic_result(parsed, target_hash)
      end

    row(:normalized_json, case_id, source, result, started, opts)
  end

  defp dsl_arm(case_id, target, target_hash, opts) do
    started = System.monotonic_time(:microsecond)

    {source, result} =
      with {:ok, source} <- DSL.render(target),
           {:ok, parsed} <- DSL.parse(source) do
        {source, semantic_result(parsed, target_hash)}
      else
        {:error, reason} -> {nil, {:error, reason}}
      end

    row(:compact_dsl, case_id, source, result, started, opts)
  end

  defp operations_arm(case_id, target_hash, opts) do
    started = System.monotonic_time(:microsecond)
    base = Keyword.get(opts, :base_ir)
    operations = Keyword.get(opts, :operations)

    cond do
      is_nil(base) or is_nil(operations) ->
        row(
          :typed_operations,
          case_id,
          nil,
          {:blocked, :operation_fixture_missing},
          started,
          opts
        )

      true ->
        source = Jason.encode!(operations)

        result =
          with {:ok, base} <- IR.from_input(base),
               {:ok, edited} <-
                 Editor.apply(base, %{
                   base_revision: base.revision,
                   base_hash: IR.semantic_hash(base),
                   operations: operations
                 }) do
            semantic_result(edited.ir, target_hash)
          end

        row(:typed_operations, case_id, source, result, started, opts)
    end
  end

  defp semantic_result(ir, target_hash) do
    actual_hash = IR.semantic_hash(ir)

    if actual_hash == target_hash do
      {:ok, %{semantic_hash: actual_hash, round_trip_fidelity: 1.0}}
    else
      {:error, %{code: :semantic_mismatch, expected: target_hash, actual: actual_hash}}
    end
  end

  defp row(arm, case_id, source, result, started, opts) do
    elapsed_us = System.monotonic_time(:microsecond) - started
    {status, diagnostics} = result_status(result)

    %{
      case_id: case_id,
      arm: arm,
      status: status,
      metrics: %{
        serialized_bytes: if(is_binary(source), do: byte_size(source), else: nil),
        local_round_trip_us: elapsed_us,
        semantic_fidelity: if(status == :pass, do: 1.0, else: 0.0),
        provider_usage: arm_usage(opts, arm)
      },
      diagnostics: diagnostics,
      artifacts: %{
        source: source,
        source_sha256: if(is_binary(source), do: sha256(source), else: nil)
      }
    }
  end

  defp result_status({:ok, data}), do: {:pass, data}
  defp result_status({:blocked, reason}), do: {:blocked, %{reason: inspect(reason)}}

  defp result_status({:error, %Error{} = error}) do
    {:fail,
     %{
       kind: error.kind,
       message: error.message,
       details: error.details,
       source: error.source,
       retryable?: error.retryable?
     }}
  end

  defp result_status({:error, reason}), do: {:fail, normalize_reason(reason)}

  defp arm_usage(opts, arm) do
    opts
    |> Keyword.get(:provider_usage, %{})
    |> Map.get(arm, Map.get(Keyword.get(opts, :provider_usage, %{}), Atom.to_string(arm)))
  end

  defp normalize_reason(reason) when is_map(reason), do: reason
  defp normalize_reason(reason), do: %{reason: inspect(reason)}

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
