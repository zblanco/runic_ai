defmodule RunicAI.Component.ContextAssemble do
  @moduledoc "Runic component for deterministic, sensitivity-aware prompt context assembly."

  require Runic

  alias RunicAI.Context.{Assembler, Window}
  alias RunicAI.Contract.Component
  alias RunicAI.Prompt

  def contract do
    Component.new!(%{
      key: "runic_ai.context.assemble",
      contract_version: "1.0.0",
      shape: "step",
      inputs: [port("request", "input", "runic.ai/context-assembly-request")],
      outputs: [port("result", "output", "runic.ai/context-assembly-result")],
      effects: [],
      replay: "pure",
      retry: false,
      implementation: %{kind: "builtin", id: "runic_ai.context.assemble", version: "1"}
    })
  end

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :context_assemble)
    assembly_opts = Keyword.drop(opts, [:name])
    Runic.step(fn input -> run(input, assembly_opts) end, name: name)
  end

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(input, opts \\ [])

  def run(input, opts) when is_map(input) do
    with {:ok, prompt} <- normalize_prompt(field(input, "prompt")),
         {:ok, window} <- normalize_window(field(input, "window")),
         {:ok, assembled, selected_window} <- Assembler.assemble(prompt, window, opts) do
      {:ok, %{"prompt" => assembled, "window" => selected_window}}
    end
  end

  def run(_input, _opts), do: {:error, [%{path: [], message: "request must be a map"}]}

  defp normalize_prompt(%Prompt{} = prompt), do: {:ok, prompt}
  defp normalize_prompt(prompt), do: Prompt.decode(prompt)

  defp normalize_window(%Window{} = window), do: {:ok, window}
  defp normalize_window(window), do: Window.decode(window)

  defp field(map, key), do: Map.get(map, key) || existing_atom_value(map, key)

  defp existing_atom_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp port(name, direction, ref),
    do: %{name: name, direction: direction, value: %{type: "ref", ref: ref, version: "v1"}}
end
