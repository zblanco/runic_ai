defmodule RunicAI.Component.LLMGenerate do
  @moduledoc "Runic component for one explicit, host-bound LLM generation call."

  require Runic

  alias RunicAI.Contract.Component
  alias RunicAI.Error
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result

  def contract do
    Component.new!(%{
      key: "runic_ai.llm.generate",
      contract_version: "1.0.0",
      shape: "step",
      inputs: [port("request", "input", "runic.ai/llm-request", "v1")],
      outputs: [port("result", "output", "runic.ai/llm-result", "v1")],
      effects: ["llm", "network"],
      replay: "effectful",
      retry: true,
      idempotency: "host_request_key",
      implementation: %{kind: "builtin", id: "runic_ai.llm.generate", version: "1"}
    })
  end

  def new(client, opts \\ []) do
    name = Keyword.get(opts, :name, :llm_generate)
    client_opts = Keyword.drop(opts, [:name])
    Runic.step(fn input -> run(input, client, client_opts) end, name: name)
  end

  @spec run(Request.t() | map(), module() | function(), keyword()) ::
          {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}
  def run(input, client, opts \\ []) do
    with {:ok, request} <- Request.normalize(input) do
      invoke(client, request, opts)
    else
      {:error, issues} ->
        {:error,
         Error.validation("invalid LLM request",
           code: "invalid_llm_request",
           source: inspect(__MODULE__),
           details: %{"issues" => issues}
         )}
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception, source: inspect(__MODULE__), code: "client_exception")}
  end

  defp invoke(client, request, opts) when is_atom(client),
    do: client.generate(request, opts) |> normalize_outcome()

  defp invoke(client, request, opts) when is_function(client, 2),
    do: client.(request, opts) |> normalize_outcome()

  defp invoke(_client, _request, _opts),
    do:
      {:error,
       Error.validation("LLM client binding must be a module or arity-2 function",
         code: "invalid_client_binding",
         source: inspect(__MODULE__)
       )}

  defp normalize_outcome({:ok, %Result{}} = outcome), do: outcome
  defp normalize_outcome({tag, %Error{}} = outcome) when tag in [:retry, :error], do: outcome

  defp normalize_outcome(_other),
    do:
      {:error,
       Error.new!(:internal, "invalid_client_result", "LLM client returned an invalid outcome",
         source: inspect(__MODULE__)
       )}

  defp port(name, direction, ref, version) do
    %{name: name, direction: direction, value: %{type: "ref", ref: ref, version: version}}
  end
end
