import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/runic_ai start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
server_enabled? = System.get_env("PHX_SERVER") || System.get_env("RUNIC_AI_SERVER")

if server_enabled? do
  config :runic_ai, RunicAIWeb.Endpoint, server: true
end

parse_ip = fn value ->
  case value |> String.to_charlist() |> :inet.parse_address() do
    {:ok, ip} -> ip
    {:error, _reason} -> {127, 0, 0, 1}
  end
end

server_port = String.to_integer(System.get_env("RUNIC_AI_PORT") || System.get_env("PORT", "4000"))

config :runic_ai, RunicAIWeb.Endpoint,
  http: [
    ip: parse_ip.(System.get_env("RUNIC_AI_IP", "127.0.0.1")),
    port: server_port
  ]

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("RUNIC_AI_SECRET_KEY_BASE") ||
      System.get_env("SECRET_KEY_BASE") ||
      Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

  host = System.get_env("PHX_HOST") || "localhost"

  config :runic_ai, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :runic_ai, RunicAIWeb.Endpoint,
    url: [host: host, port: server_port, scheme: "http"],
    http: [
      ip: parse_ip.(System.get_env("RUNIC_AI_IP", "127.0.0.1")),
      port: server_port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :runic_ai, RunicAIWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :runic_ai, RunicAIWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
