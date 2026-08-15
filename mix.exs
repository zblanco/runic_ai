defmodule RunicAI.MixProject do
  use Mix.Project

  @version "0.2.0-alpha.1"
  @source_url "https://github.com/zblanco/runic_ai"

  def project do
    [
      app: :runic_ai,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      description: "Portable AI contracts and Runic workflow components",
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:runic, "~> 0.1.0-alpha.8"},
      {:req_llm, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:zoi, "~> 0.17.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib guides mix.exs README.md CHANGELOG.md .formatter.exs),
      licenses: ["MIT"],
      links: %{"Source" => @source_url}
    ]
  end
end
