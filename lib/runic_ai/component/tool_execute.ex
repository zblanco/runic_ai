defmodule RunicAI.Component.ToolExecute do
  @moduledoc "Runic component for a single host-resolved tool call."

  require Runic

  alias RunicAI.Contract.Component
  alias RunicAI.Error
  alias RunicAI.Tool.Binding
  alias RunicAI.Tool.Call
  alias RunicAI.Tool.Executor
  alias RunicAI.Tool.Result

  def contract do
    Component.new!(%{
      key: "runic_ai.tool.execute",
      contract_version: "1.0.0",
      shape: "step",
      inputs: [port("call", "input", "runic.ai/tool-call")],
      outputs: [port("result", "output", "runic.ai/tool-result")],
      effects: [
        "workspace_read",
        "workspace_write",
        "network",
        "external_mutation",
        "child_workflow",
        "sandbox"
      ],
      replay: "effectful",
      retry: false,
      implementation: %{kind: "builtin", id: "runic_ai.tool.execute", version: "1"}
    })
  end

  def new(resolver, opts \\ []) do
    name = Keyword.get(opts, :name, :tool_execute)
    context = Keyword.get(opts, :context, %{})
    Runic.step(fn input -> run(input, resolver, context) end, name: name)
  end

  @spec run(Call.t() | map(), function(), map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(input, resolver, context \\ %{}) when is_function(resolver, 2) do
    with {:ok, call} <- normalize_call(input),
         {:ok, binding} <- resolve(resolver, call, context) do
      Executor.execute(call, binding, context)
    end
  end

  defp normalize_call(%Call{} = call), do: {:ok, call}
  defp normalize_call(input), do: Call.new(input)

  defp resolve(resolver, call, context) do
    case resolver.(call.tool, context) do
      %Binding{} = binding ->
        {:ok, binding}

      {:ok, %Binding{} = binding} ->
        {:ok, binding}

      nil ->
        {:ok, nil}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        {:error,
         Error.new!(
           :internal,
           "invalid_binding_resolver_result",
           "binding resolver returned an invalid result", source: inspect(__MODULE__))}
    end
  end

  defp port(name, direction, ref),
    do: %{name: name, direction: direction, value: %{type: "ref", ref: ref, version: "v1"}}
end
