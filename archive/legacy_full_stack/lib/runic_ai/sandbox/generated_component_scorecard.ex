defmodule RunicAI.Sandbox.GeneratedComponentScorecard do
  @moduledoc """
  Separates generated-component contract, verification, and final objective scores.

  The normal objective scorecard answers "did this workflow satisfy the user
  objective?" This scorecard answers narrower questions that are useful before
  composing or promoting sandbox-generated code: is the component contract
  complete, is verification evidence present and passing, and what did the
  downstream objective scorecard say, if one exists?
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent

  @spec run(GeneratedComponent.t() | map() | keyword(), keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(component_input, opts \\ []) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input) do
      opts = opts_map(opts)
      contract_risks = contract_risks(component)
      verification_risks = verification_risks(component)
      objective_scorecard = get(opts, :objective_scorecard, nil)

      {:ok,
       %{
         id: "generated_component_scorecard:#{component.id}",
         component_id: component.id,
         contract_status: status(contract_risks),
         verification_status: verification_status(component, verification_risks),
         final_objective_status: objective_status(objective_scorecard),
         promotion_status: component.promotion_status,
         promotable?: GeneratedComponent.promotable?(component),
         contract_risks: contract_risks,
         verification_risks: verification_risks,
         objective_residual_risks: objective_residual_risks(objective_scorecard),
         residual_risks:
           contract_risks ++ verification_risks ++ objective_residual_risks(objective_scorecard),
         source_artifact_count: length(component.source_artifacts),
         test_artifact_count: length(component.test_artifacts)
       }}
    end
  end

  defp contract_risks(%GeneratedComponent{} = component) do
    []
    |> maybe_risk(component.source_artifacts == [], "source artifacts are missing")
    |> maybe_risk(
      interface_ports(component.interface, :inputs) == [],
      "declared inputs are missing"
    )
    |> maybe_risk(
      interface_ports(component.interface, :outputs) == [],
      "declared outputs are missing"
    )
  end

  defp verification_risks(%GeneratedComponent{} = component) do
    verification_status = verification_status_value(component.verification)

    []
    |> maybe_risk(
      verification_status not in [:pass, :passed, :ok],
      "verification status is not passing"
    )
    |> maybe_risk(component.test_artifacts == [], "test artifacts are missing")
    |> maybe_risk(
      not has_verification_command?(component.verification),
      "verification command is missing"
    )
  end

  defp status([]), do: :pass
  defp status(_risks), do: :incomplete

  defp verification_status(%GeneratedComponent{} = component, risks) do
    case verification_status_value(component.verification) do
      status when status in [:fail, :failed, :error] -> :failed
      status when status in [:pass, :passed, :ok] -> status(risks)
      _other -> :incomplete
    end
  end

  defp objective_status(nil), do: :not_evaluated

  defp objective_status(scorecard) when is_map(scorecard),
    do: get(scorecard, :objective_status, :unknown)

  defp objective_status(_scorecard), do: :unknown

  defp objective_residual_risks(nil), do: []

  defp objective_residual_risks(scorecard) when is_map(scorecard) do
    scorecard
    |> get(:residual_risks, [])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp objective_residual_risks(_scorecard), do: ["objective scorecard was not a map"]

  defp interface_ports(interface, key) when is_map(interface) do
    case get(interface, key, []) do
      ports when is_list(ports) -> ports
      _other -> []
    end
  end

  defp interface_ports(_interface, _key), do: []

  defp verification_status_value(verification) when is_map(verification) do
    verification
    |> get(:status, nil)
    |> normalize_status()
  end

  defp verification_status_value(_verification), do: nil

  defp normalize_status(value) when is_atom(value), do: value

  defp normalize_status(value) when is_binary(value) do
    case String.downcase(value) do
      "pass" -> :pass
      "passed" -> :passed
      "ok" -> :ok
      "fail" -> :fail
      "failed" -> :failed
      "error" -> :error
      _other -> nil
    end
  end

  defp normalize_status(_value), do: nil

  defp has_verification_command?(verification) when is_map(verification) do
    case get(verification, :command, nil) do
      command when is_binary(command) -> String.trim(command) != ""
      _other -> false
    end
  end

  defp has_verification_command?(_verification), do: false

  defp maybe_risk(risks, true, risk), do: risks ++ [risk]
  defp maybe_risk(risks, false, _risk), do: risks

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
