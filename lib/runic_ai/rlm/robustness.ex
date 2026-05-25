defmodule RunicAI.RLM.Robustness do
  @moduledoc """
  Facade for RLM robustness scenario catalog and smoke runner.
  """

  alias RunicAI.RLM.Robustness.Catalog
  alias RunicAI.RLM.Robustness.Runner

  defdelegate scenarios(), to: Catalog, as: :all
  defdelegate scenario(id), to: Catalog, as: :get
  defdelegate run_matrix(ids \\ nil, opts \\ []), to: Runner
end
