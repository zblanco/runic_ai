defmodule RunicAI.Tool.ExecutionAdapter do
  @moduledoc """
  Behaviour and helpers for runtime execution adapters behind tool definitions.

  Adapters expose execution environments as ordinary tool executors. Their
  results should normalize to `{:ok, value}` or `{:error, RunicAI.Error.t()}` so
  existing tool call result handling remains the visible contract.
  """

  alias RunicAI.Error

  @callback execute(map(), keyword()) :: {:ok, term()} | {:error, Error.t()} | term()

  @spec to_executor(module(), keyword()) :: (map() ->
                                               {:ok, term()} | {:error, Error.t()} | term())
  def to_executor(module, opts \\ []) when is_atom(module) and is_list(opts) do
    fn arguments -> execute(module, arguments, opts) end
  end

  @spec execute(module(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()} | term()
  def execute(module, arguments, opts \\ [])
      when is_atom(module) and is_map(arguments) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :execute, 2) do
      module.execute(arguments, opts)
    else
      {:error,
       Error.validation("tool execution adapter must export execute/2",
         source: __MODULE__,
         details: %{module: module}
       )}
    end
  end
end
