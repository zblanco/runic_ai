defmodule RunicAI.RLM.Components.ArtifactMaterializer do
  @moduledoc """
  Bounded artifact materialization for assistant/RLM workflows.

  This component turns artifact refs and inline artifact metadata into
  prompt-safe previews. It is deliberately read-only; materializing an artifact
  into the host workspace should go through `ArtifactWriter` or a future
  reviewed promotion component.
  """

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_max_bytes 4_000
  @default_max_artifacts 20

  @spec run(Workspace.t(), term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, input, params \\ %{}) do
    params = opts_map(params)
    max_bytes = positive_integer(params, :max_bytes, @default_max_bytes)
    max_artifacts = positive_integer(params, :max_artifacts, @default_max_artifacts)

    refs = artifact_refs(input, params)
    inline_artifacts = inline_artifacts(input, params)

    with {:ok, persisted} <- persisted_artifacts(workspace, refs, max_bytes) do
      artifacts =
        (persisted ++ Enum.map(inline_artifacts, &materialize_inline(&1, max_bytes)))
        |> Enum.reject(&is_nil/1)

      selected = Enum.take(artifacts, max_artifacts)
      total_bytes = Enum.reduce(selected, 0, &(&2 + byte_size(&1.text || "")))

      {:ok,
       %{
         slices: selected,
         count: length(selected),
         input_count: length(artifacts),
         total_bytes: total_bytes,
         truncated?: length(artifacts) > length(selected) or Enum.any?(selected, & &1.truncated?)
       }}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp persisted_artifacts(%Workspace{} = workspace, refs, max_bytes) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case Persistence.get_artifact(workspace.persistence, ref) do
        {:ok, nil} ->
          {:cont, {:ok, [missing_artifact(ref) | acc]}}

        {:ok, artifact} ->
          {:cont, {:ok, [materialize_persisted(ref, artifact, max_bytes) | acc]}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      other -> other
    end
  end

  defp materialize_persisted(ref, artifact, max_bytes) when is_map(artifact) do
    content =
      artifact
      |> get(:content, get(artifact, :preview, artifact))
      |> stringify()

    {preview, truncated?} = preview(content, max_bytes)

    %{
      id: ref,
      ref: ref,
      kind: get(artifact, :kind, :artifact),
      text: preview,
      byte_size: byte_size(content),
      truncated?: truncated?,
      provenance: [%{artifact_ref: ref}],
      metadata: Map.drop(artifact, [:content, "content", :preview, "preview"])
    }
  end

  defp materialize_inline(artifact, max_bytes) when is_map(artifact) do
    ref = get(artifact, :ref, get(artifact, :artifact_ref, nil))
    path = get(artifact, :path, nil)

    content =
      artifact
      |> get(:preview, get(artifact, :content, artifact))
      |> stringify()

    {preview, truncated?} = preview(content, max_bytes)

    %{
      id: ref || path || "inline_artifact",
      ref: ref,
      path: path,
      kind: get(artifact, :kind, :sandbox_artifact),
      text: preview,
      byte_size: get(artifact, :bytes, byte_size(content)),
      truncated?: truncated? or get(artifact, :truncated?, false) in [true, "true"],
      provenance: [%{artifact_ref: ref, path: path}],
      metadata: Map.drop(artifact, [:content, "content", :preview, "preview"])
    }
  end

  defp materialize_inline(_artifact, _max_bytes), do: nil

  defp missing_artifact(ref) do
    %{
      id: ref,
      ref: ref,
      kind: :missing_artifact,
      text: "",
      byte_size: 0,
      truncated?: false,
      missing?: true,
      provenance: [%{artifact_ref: ref}],
      metadata: %{}
    }
  end

  defp artifact_refs(input, params) do
    explicit =
      params
      |> get(:artifact_refs, [])
      |> List.wrap()

    single =
      params
      |> get(:artifact_ref, nil)
      |> List.wrap()

    (explicit ++ single ++ collect_refs(input))
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
  end

  defp inline_artifacts(input, params) do
    params_artifacts =
      params
      |> get(:artifacts, [])
      |> List.wrap()

    params_artifacts ++ collect_inline_artifacts(input)
  end

  defp collect_refs(%_struct{} = value), do: value |> Map.from_struct() |> collect_refs()

  defp collect_refs(value) when is_map(value) do
    own =
      [get(value, :artifact_ref, nil)]
      |> Enum.filter(&is_binary/1)

    nested =
      value
      |> Map.values()
      |> Enum.flat_map(&collect_refs/1)

    own ++ nested
  end

  defp collect_refs(values) when is_list(values), do: Enum.flat_map(values, &collect_refs/1)
  defp collect_refs(_value), do: []

  defp collect_inline_artifacts(%_struct{} = value),
    do: value |> Map.from_struct() |> collect_inline_artifacts()

  defp collect_inline_artifacts(value) when is_map(value) do
    own =
      case {get(value, :artifacts, nil), get(value, :ref, nil), get(value, :preview, nil)} do
        {artifacts, _ref, _preview} when is_list(artifacts) ->
          artifacts

        {_artifacts, ref, preview} when is_binary(ref) or is_binary(preview) ->
          [value]

        _other ->
          []
      end

    nested =
      value
      |> Map.drop([:artifacts, "artifacts"])
      |> Map.values()
      |> Enum.flat_map(&collect_inline_artifacts/1)

    own ++ nested
  end

  defp collect_inline_artifacts(values) when is_list(values),
    do: Enum.flat_map(values, &collect_inline_artifacts/1)

  defp collect_inline_artifacts(_value), do: []

  defp preview(content, max_bytes) do
    size = byte_size(content)
    preview = binary_part(content, 0, min(size, max_bytes))
    {preview, size > byte_size(preview)}
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp positive_integer(params, key, default) do
    case get(params, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
