defmodule RunicAI.ServerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Server
  alias RunicAI.Server.Desktop

  test "parses the local server command contract" do
    assert {:ok, opts} =
             Server.parse([
               "--port",
               "4100",
               "--ip",
               "127.0.0.1",
               "--data-path",
               "tmp/server-contract",
               "--database",
               "tmp/server-contract/runs.db",
               "--token",
               "test-token",
               "--no-open",
               "--log-level",
               "warning"
             ])

    assert opts.port == 4100
    assert opts.ip == "127.0.0.1"
    assert opts.ip_tuple == {127, 0, 0, 1}
    assert opts.token == "test-token"
    assert opts.open_browser? == false
    assert opts.log_level == :warning
    assert String.ends_with?(opts.database, "tmp/server-contract/runs.db")
  end

  test "builds tokenized local URLs" do
    assert {:ok, opts} = Server.parse(["--port", "4101", "--token", "abc123"])
    assert Server.tokenized_url(opts) == "http://localhost:4101/?token=abc123"
  end

  test "desktop spike delegates to the same server command" do
    assert Desktop.server_args(port: 4102, data_path: "/tmp/runic-ai", open_browser: false) == [
             "server",
             "--port",
             "4102",
             "--data-path",
             "/tmp/runic-ai",
             "--no-open"
           ]

    assert Desktop.entry_route(route: "/sessions/new") == "/sessions/new"
  end
end
