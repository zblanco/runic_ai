defmodule RunicAI.REPLFakeSandboxRegistry do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def requests(pid), do: GenServer.call(pid, :requests)

  @impl true
  def init(opts) do
    {:ok, %{response: Keyword.fetch!(opts, :response), requests: []}}
  end

  @impl true
  def handle_call({:exec, session_id, request, opts}, _from, state) do
    request_record = %{session_id: session_id, request: request, opts: opts}

    response =
      case state.response do
        fun when is_function(fun, 1) -> fun.(request_record)
        fun when is_function(fun, 3) -> fun.(session_id, request, opts)
        response -> response
      end

    {:reply, response, %{state | requests: state.requests ++ [request_record]}}
  end

  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}
end
