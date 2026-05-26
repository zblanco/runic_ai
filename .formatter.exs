# Used by "mix format"
[
  import_deps: [:ecto_sql, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "packages/*/{mix,.formatter}.exs",
    "packages/*/{lib,test}/**/*.{ex,exs}",
    "priv/**/*.{ex,exs}",
    "scripts/**/*.{ex,exs}"
  ]
]
