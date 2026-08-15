defmodule RunicAI.Coding.WorkspaceDelta do
  @moduledoc """
  Shared workspace snapshot and delta API for coding repair loops.
  """

  alias RunicAI.Coding.RLM.WorkspaceDelta, as: Impl

  @type file_info :: Impl.file_info()
  @type snapshot :: Impl.snapshot()
  @type delta :: Impl.delta()

  defdelegate snapshot(workspace, opts \\ []), to: Impl
  defdelegate diff(before_snapshot, after_snapshot), to: Impl
  defdelegate changed_paths(delta), to: Impl
end
