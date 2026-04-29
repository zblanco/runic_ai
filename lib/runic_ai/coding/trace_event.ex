defmodule RunicAI.Coding.TraceEvent do
  @moduledoc """
  Trace event constructors for coding harness activity.
  """

  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Trace.Event

  @type coding_kind ::
          :coding_file_read
          | :coding_search
          | :coding_patch
          | :coding_command
          | :coding_process

  @spec file_read(Path.t(), map(), keyword()) :: Event.t()
  def file_read(path, payload, opts \\ []) when is_binary(path) and is_map(payload) do
    new(:coding_file_read, payload, Keyword.put(opts, :path, path))
  end

  @spec search(map(), keyword()) :: Event.t()
  def search(payload, opts \\ []) when is_map(payload) do
    new(:coding_search, payload, opts)
  end

  @spec patch(map(), keyword()) :: Event.t()
  def patch(payload, opts \\ []) when is_map(payload) do
    new(:coding_patch, payload, opts)
  end

  @spec command(map(), keyword()) :: Event.t()
  def command(payload, opts \\ []) when is_map(payload) do
    new(:coding_command, payload, opts)
  end

  @spec process(map(), keyword()) :: Event.t()
  def process(payload, opts \\ []) when is_map(payload) do
    new(:coding_process, payload, opts)
  end

  @spec new(coding_kind(), map(), keyword()) :: Event.t()
  def new(kind, payload, opts \\ []) when is_atom(kind) and is_map(payload) and is_list(opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.merge(%{
        coding?: true,
        workspace_root: Keyword.get(opts, :workspace_root),
        path: Keyword.get(opts, :path),
        tool_name: Keyword.get(opts, :tool_name),
        artifact_ref: artifact_ref(payload)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Event.new!(kind,
      status: Keyword.get(opts, :status),
      input: TraceRedactor.redact(Keyword.get(opts, :input)),
      output: TraceRedactor.redact(payload),
      measurements: Keyword.get(opts, :measurements, %{}),
      metadata: metadata
    )
  end

  defp artifact_ref(payload) do
    Map.get(payload, :artifact_ref) || Map.get(payload, "artifact_ref")
  end
end
