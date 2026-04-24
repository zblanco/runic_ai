defmodule RunicAI.Runtime.Handle do
  @moduledoc """
  Stable reference to a supervised RunicAI runtime session.
  """

  alias RunicAI.Error
  alias RunicAI.Runtime.SessionSpec

  @enforce_keys [:id, :server, :kind, :recipe, :backend, :metadata]
  defstruct [:id, :server, :kind, :recipe, :backend, :runner_workflow_id, metadata: %{}]

  @type server_ref :: pid() | atom() | {:via, module(), term()}

  @type t :: %__MODULE__{
          id: String.t(),
          server: server_ref(),
          kind: :turn_processor | :integrated,
          recipe: module(),
          backend: module(),
          runner_workflow_id: term(),
          metadata: map()
        }

  @spec new(SessionSpec.t(), server_ref(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%SessionSpec{} = spec, server, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, spec.metadata)

    with :ok <- validate_server(server),
         :ok <- validate_map(metadata, :metadata) do
      {:ok,
       %__MODULE__{
         id: spec.id,
         server: server,
         kind: spec.kind,
         recipe: spec.recipe,
         backend: spec.backend,
         runner_workflow_id: Keyword.get(opts, :runner_workflow_id, spec.runner_workflow_id),
         metadata: metadata
       }}
    end
  end

  @spec new!(SessionSpec.t(), server_ref(), keyword()) :: t()
  def new!(%SessionSpec{} = spec, server, opts \\ []) do
    case new(spec, server, opts) do
      {:ok, handle} -> handle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec server(t() | server_ref()) :: server_ref()
  def server(%__MODULE__{server: server}), do: server
  def server(server), do: server

  defp validate_server(server) when is_pid(server), do: :ok
  defp validate_server(server) when is_atom(server), do: :ok
  defp validate_server({:via, module, _term}) when is_atom(module), do: :ok

  defp validate_server(server) do
    {:error,
     Error.validation("runtime handle server must be a pid, atom, or via tuple",
       source: __MODULE__,
       details: %{server: server}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("runtime handle #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
