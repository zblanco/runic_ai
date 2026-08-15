import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :runic_ai, RunicAIWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4f5tiOdW3RvZ41dKw+AuDZ+DhOqvvFMVlK1RiCKgoP2LuE9vnEPu+lCsgpJ8Cys6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :runic_ai, :workbench,
  data_path: "tmp/test-runic-ai",
  database: ":memory:",
  migrate?: true,
  default_agent: :assistant,
  default_model: nil,
  default_client: nil,
  default_approval: :safe,
  default_mode: :verify,
  default_write_policy: :docs_only,
  theme: :runic
