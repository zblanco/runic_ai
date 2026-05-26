defmodule RunicAI.GeneratedComponentFakeSandboxRegistry do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def writes(pid), do: GenServer.call(pid, :writes)
  def execs(pid), do: GenServer.call(pid, :execs)

  @impl true
  def init(opts) do
    {:ok,
     %{
       exec_responses: Keyword.get(opts, :exec_responses, []),
       exec_fun: Keyword.get(opts, :exec_fun),
       writes: [],
       execs: []
     }}
  end

  @impl true
  def handle_call({:write_file, session_id, path, contents, opts}, _from, state) do
    write = %{session_id: session_id, path: path, contents: contents, opts: opts}

    ref = %{
      ref: "artifact://#{path}",
      path: path,
      bytes: byte_size(to_string(contents)),
      sha256: :crypto.hash(:sha256, to_string(contents)) |> Base.encode16(case: :lower)
    }

    {:reply, {:ok, ref}, %{state | writes: state.writes ++ [write]}}
  end

  def handle_call({:exec, session_id, request, opts}, _from, state) do
    exec = %{session_id: session_id, request: request, opts: opts}
    {response, exec_responses} = next_exec_response(state, exec)

    {:reply, response, %{state | execs: state.execs ++ [exec], exec_responses: exec_responses}}
  end

  def handle_call(:writes, _from, state), do: {:reply, state.writes, state}
  def handle_call(:execs, _from, state), do: {:reply, state.execs, state}

  defp next_exec_response(%{exec_fun: fun, exec_responses: responses}, exec)
       when is_function(fun, 1) do
    {fun.(exec), responses}
  end

  defp next_exec_response(%{exec_responses: [response | rest]}, _exec), do: {response, rest}

  defp next_exec_response(%{exec_responses: []}, _exec) do
    {{:ok, %{status: :ok, exit_status: 0, stdout: "", stderr: ""}}, []}
  end
end
