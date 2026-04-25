defmodule RunicAI do
  @external_resource Path.expand("../README.md", __DIR__)
  @moduledoc File.read!(Path.expand("../README.md", __DIR__))
end
