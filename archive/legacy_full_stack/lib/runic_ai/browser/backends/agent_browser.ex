defmodule RunicAI.Browser.Backends.AgentBrowser do
  @moduledoc """
  Local `agent-browser` CLI backend.

  This adapter intentionally keeps to the CLI's snapshot/ref workflow. It is a
  best-effort local backend: if the executable is absent, initialization fails
  cleanly and callers can fall back to a fake or remote backend.
  """

  @behaviour RunicAI.Browser.Backend

  alias RunicAI.Error

  @impl true
  def init(opts) do
    executable = Keyword.get(opts, :executable) || System.find_executable("agent-browser")

    if executable do
      {:ok,
       %{executable: executable, cwd: Keyword.get(opts, :cwd), env: Keyword.get(opts, :env, [])}}
    else
      {:error,
       Error.validation("agent-browser executable is not available",
         source: __MODULE__,
         details: %{executable: "agent-browser"}
       )}
    end
  end

  @impl true
  def navigate(state, url, _args), do: command(state, ["open", url, "--json"], :navigated)

  @impl true
  def snapshot(state, _args), do: command(state, ["snapshot", "-i", "--json"], :snapshot)

  @impl true
  def click(state, selector, _args), do: command(state, ["click", selector, "--json"], :clicked)

  @impl true
  def type(state, selector, text, _args),
    do: command(state, ["fill", selector, text, "--json"], :typed)

  @impl true
  def press(state, key, _args), do: command(state, ["press", key, "--json"], :pressed)

  @impl true
  def scroll(state, args) do
    direction = Map.get(args, :direction, Map.get(args, "direction", "down"))
    command(state, ["scroll", direction, "--json"], :scrolled)
  end

  @impl true
  def console(state, _args), do: command(state, ["console", "--json"], :console)

  @impl true
  def screenshot(state, args) do
    path = Map.get(args, :path, Map.get(args, "path", temp_screenshot_path()))

    case System.cmd(state.executable, ["screenshot", path], command_opts(state)) do
      {_output, 0} ->
        case File.read(path) do
          {:ok, image} ->
            {:ok, state,
             %{
               status: :ok,
               path: path,
               image: image,
               media_type: "image/png",
               byte_size: byte_size(image)
             }}

          {:error, reason} ->
            {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      {output, status} ->
        {:error,
         Error.validation("agent-browser screenshot failed",
           source: __MODULE__,
           details: %{status: status, output: output}
         )}
    end
  end

  @impl true
  def close(_state), do: :ok

  defp command(state, args, action) do
    case System.cmd(state.executable, args, command_opts(state)) do
      {output, 0} ->
        {:ok, state, normalize_output(output, action)}

      {output, status} ->
        {:error,
         Error.validation("agent-browser command failed",
           source: __MODULE__,
           details: %{args: args, status: status, output: output}
         )}
    end
  end

  defp normalize_output(output, action) do
    decoded =
      case Jason.decode(output) do
        {:ok, json} -> json
        {:error, _reason} -> %{"text" => output}
      end

    data = Map.get(decoded, "data", decoded)
    snapshot = Map.get(data, "snapshot") || Map.get(data, "text") || output

    %{
      status: :ok,
      action: action,
      snapshot: snapshot,
      refs: Map.get(data, "refs", %{}),
      raw: decoded
    }
  end

  defp command_opts(state) do
    [stderr_to_stdout: true]
    |> maybe_put(:cd, state.cwd)
    |> maybe_put(:env, state.env)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp temp_screenshot_path do
    Path.join(System.tmp_dir!(), "runic-ai-browser-#{System.unique_integer([:positive])}.png")
  end
end
