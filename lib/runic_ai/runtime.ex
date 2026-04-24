defmodule RunicAI.Runtime do
  @moduledoc """
  Public OTP runtime facade for supervised RunicAI harness sessions.
  """

  alias RunicAI.Runtime.Handle
  alias RunicAI.Runtime.Registry, as: RuntimeRegistry
  alias RunicAI.Runtime.SessionServer
  alias RunicAI.Runtime.SessionSpec
  alias RunicAI.Runtime.SessionSupervisor

  @spec start_session(SessionSpec.t() | keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def start_session(spec_or_opts) do
    spec = SessionSpec.from_input!(spec_or_opts)

    case SessionSupervisor.start_session(spec) do
      {:ok, pid} ->
        {:ok, SessionServer.handle(pid)}

      {:error, {:already_started, pid}} ->
        {:ok, SessionServer.handle(pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec start_session_link(SessionSpec.t() | keyword()) ::
          {:ok, Handle.t()} | {:error, term()}
  def start_session_link(spec_or_opts) do
    with {:ok, pid} <- SessionServer.start_link(spec_or_opts) do
      {:ok, SessionServer.handle(pid)}
    end
  end

  @spec submit(Handle.t() | GenServer.server(), term()) :: {:ok, RunicAI.Harness.Session.t()}
  def submit(handle_or_server, input), do: SessionServer.submit(server(handle_or_server), input)

  @spec advance(Handle.t() | GenServer.server(), RunicAI.Harness.Policy.t() | keyword() | nil) ::
          {:ok, RunicAI.Harness.Session.t()}
  def advance(handle_or_server, policy \\ nil),
    do: SessionServer.advance(server(handle_or_server), policy)

  @spec drain(Handle.t() | GenServer.server(), RunicAI.Harness.Policy.t() | keyword() | nil) ::
          {:ok, RunicAI.Harness.Session.t()}
  def drain(handle_or_server, policy \\ nil),
    do: SessionServer.drain(server(handle_or_server), policy)

  @spec snapshot(Handle.t() | GenServer.server()) :: RunicAI.Harness.Session.t()
  def snapshot(handle_or_server), do: SessionServer.snapshot(server(handle_or_server))

  @spec outputs(Handle.t() | GenServer.server()) :: list()
  def outputs(handle_or_server), do: SessionServer.outputs(server(handle_or_server))

  @spec trajectory(Handle.t() | GenServer.server()) :: RunicAI.Trace.Trajectory.t()
  def trajectory(handle_or_server), do: SessionServer.trajectory(server(handle_or_server))

  @spec subscribe(Handle.t() | GenServer.server()) :: :ok
  def subscribe(handle_or_server), do: SessionServer.subscribe(server(handle_or_server))

  @spec unsubscribe(Handle.t() | GenServer.server()) :: :ok
  def unsubscribe(handle_or_server), do: SessionServer.unsubscribe(server(handle_or_server))

  @spec stop(Handle.t() | GenServer.server()) :: :ok
  def stop(handle_or_server) do
    handle_or_server
    |> server()
    |> GenServer.stop(:normal, :infinity)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :noproc -> :ok
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id), do: RuntimeRegistry.whereis(session_id)

  defp server(%Handle{} = handle), do: Handle.server(handle)
  defp server(server), do: server
end
