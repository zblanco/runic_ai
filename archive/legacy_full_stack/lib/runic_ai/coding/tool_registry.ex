defmodule RunicAI.Coding.ToolRegistry do
  @moduledoc """
  Small facade for constructing coding tool registries.
  """

  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Tool.Registry

  @spec default(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: Registry.t()
  def default(workspace, opts \\ []) do
    Tools.default_registry(workspace, opts)
  end
end
