defmodule RunicAI.Server.Desktop do
  @moduledoc """
  Small desktop-wrapper contract for the local workbench.

  A future Tauri, ElixirKit-style, or OS-specific launcher should call the same
  `runic_ai server` entrypoint and open the same tokenized Phoenix routes that
  the browser server uses. This module keeps that contract executable instead
  of making the desktop spike a separate application path.
  """

  @spec server_args(keyword()) :: [String.t()]
  def server_args(opts \\ []) do
    ["server"] ++ option_args(opts)
  end

  @spec entry_route(keyword()) :: String.t()
  def entry_route(opts \\ []) do
    Keyword.get(opts, :route, "/")
  end

  defp option_args(opts) do
    opts
    |> Enum.flat_map(fn
      {:port, port} -> ["--port", to_string(port)]
      {:ip, ip} -> ["--ip", to_string(ip)]
      {:data_path, path} -> ["--data-path", to_string(path)]
      {:database, path} -> ["--database", to_string(path)]
      {:token, token} -> ["--token", to_string(token)]
      {:open_browser, true} -> ["--open-browser"]
      {:open_browser, false} -> ["--no-open"]
      {:log_level, level} -> ["--log-level", to_string(level)]
      {:route, _route} -> []
    end)
  end
end
