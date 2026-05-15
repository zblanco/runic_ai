defmodule RunicAIWeb.Plugs.LocalAuth do
  @moduledoc """
  Minimal local-token guard for the browser workbench.

  When `:auth_required?` and `:auth_token` are set in the workbench config, a
  request must either include the token as `?token=...` or already have it in
  the browser session.
  """

  import Plug.Conn

  @session_key :runic_ai_local_auth_token
  @public_paths MapSet.new(["/health"])

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:runic_ai, :workbench, [])
    required? = Keyword.get(config, :auth_required?, false)
    token = Keyword.get(config, :auth_token)

    cond do
      not required? ->
        conn

      not is_binary(token) or token == "" ->
        conn

      MapSet.member?(@public_paths, conn.request_path) ->
        conn

      session_authorized?(conn, token) ->
        conn

      request_authorized?(conn, token) ->
        put_session(conn, @session_key, token)

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:unauthorized, "RunicAI local access token required\n")
        |> halt()
    end
  end

  defp session_authorized?(conn, token) do
    conn
    |> get_session(@session_key)
    |> secure_equal?(token)
  end

  defp request_authorized?(conn, token) do
    conn
    |> fetch_query_params()
    |> Map.get(:query_params, %{})
    |> Map.get("token")
    |> secure_equal?(token)
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false
end
