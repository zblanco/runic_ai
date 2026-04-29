defmodule RunicAI.Coding.Harness do
  @moduledoc """
  Minimal local harness for exercising coding tools.
  """

  alias RunicAI.Coding.Tools
  alias RunicAI.Error
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  @spec run_tool(term(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def run_tool(workspace, tool_name, arguments, opts \\ [])
      when is_binary(tool_name) and is_map(arguments) and is_list(opts) do
    registry = Tools.default_registry(workspace, opts)

    with {:ok, definition} <- Registry.fetch(registry, tool_name) do
      Definition.execute(definition, arguments)
    end
  end
end
