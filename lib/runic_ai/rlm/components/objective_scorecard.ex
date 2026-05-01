defmodule RunicAI.RLM.Components.ObjectiveScorecard do
  @moduledoc """
  Reusable objective verification for generated RLM workflows.

  This component checks durable artifacts, required sections, optional schema
  fields, source/provenance coverage, and budget summaries. It does not trust a
  final LLM completion claim as proof of success.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Components.BudgetLedger

  @spec run(Workspace.t(), map(), term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, context, input, params \\ %{}) when is_map(context) do
    params = opts_map(params)
    artifact_path = artifact_path(context, params)
    required_sections = string_list(get(params, :required_sections, []))
    required_schema_fields = string_list(get(params, :required_schema_fields, []))

    required_source_cues =
      string_list(get(params, :required_source_cues, get(params, :source_cues, [])))

    require_provenance? = truthy?(get(params, :require_provenance?, false))
    require_artifact_quality? = truthy?(get(params, :require_artifact_quality?, false))

    text = output_text(input) || artifact_text(workspace, artifact_path) || ""
    artifact_status = artifact_status(workspace, artifact_path)
    missing_sections = missing_sections(text, required_sections)
    missing_schema_fields = missing_schema_fields(input, text, required_schema_fields)
    missing_source_cues = missing_source_cues(text, required_source_cues)
    artifact_quality = artifact_quality(text)
    source_count = source_count(context)
    provenance_count = provenance_count(input) + provenance_count(context)
    artifact_bytes = artifact_bytes(workspace, artifact_path)

    coverage_status =
      cond do
        source_count == 0 -> :not_required
        provenance_count > 0 -> :present
        require_provenance? -> :missing
        true -> :not_required
      end

    source_cue_status =
      cond do
        required_source_cues == [] -> :not_required
        missing_source_cues == [] -> :present
        true -> :missing
      end

    residual_risks =
      residual_risks(
        artifact_status,
        missing_sections,
        missing_schema_fields,
        coverage_status,
        text,
        missing_source_cues,
        artifact_quality,
        require_artifact_quality?
      )

    objective_status =
      if residual_risks == [] do
        :objective_satisfied
      else
        :objective_incomplete
      end

    {:ok,
     %{
       id: get(params, :id, "scorecard:objective"),
       objective_status: objective_status,
       artifact_status: artifact_status,
       artifact_path: artifact_path,
       artifact_bytes: artifact_bytes,
       required_sections: required_sections,
       missing_sections: missing_sections,
       required_schema_fields: required_schema_fields,
       missing_schema_fields: missing_schema_fields,
       required_source_cues: required_source_cues,
       missing_source_cues: missing_source_cues,
       source_cue_status: source_cue_status,
       artifact_quality: artifact_quality,
       source_count: source_count,
       source_coverage: coverage_status,
       provenance_count: provenance_count,
       budget_summary: BudgetLedger.summary(get(context, :budget_ledger, nil)),
       residual_risks: residual_risks
     }}
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp artifact_path(context, params) do
    get(params, :artifact_path, nil) ||
      context
      |> get(:artifacts, [])
      |> List.wrap()
      |> List.last()
      |> case do
        nil -> nil
        artifact -> get(artifact, :path, nil)
      end
  end

  defp artifact_status(_workspace, nil), do: :not_required
  defp artifact_status(_workspace, ""), do: :not_required

  defp artifact_status(workspace, path) do
    if artifact_exists?(workspace, path), do: :present, else: :missing
  end

  defp artifact_exists?(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      File.regular?(resolved.path)
    else
      _other -> false
    end
  end

  defp artifact_text(_workspace, nil), do: nil
  defp artifact_text(_workspace, ""), do: nil

  defp artifact_text(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, text} <- File.read(resolved.path) do
      text
    else
      _other -> nil
    end
  end

  defp artifact_bytes(_workspace, nil), do: nil
  defp artifact_bytes(_workspace, ""), do: nil

  defp artifact_bytes(workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, stat} <- File.stat(resolved.path) do
      stat.size
    else
      _other -> nil
    end
  end

  defp missing_sections(text, required_sections) do
    normalized = String.downcase(text || "")

    Enum.reject(required_sections, fn section ->
      String.contains?(normalized, String.downcase(section))
    end)
  end

  defp missing_schema_fields(_input, _text, []), do: []

  defp missing_schema_fields(input, text, required_fields) do
    value =
      cond do
        is_map(input) -> input
        is_binary(text) -> decode_json(text)
        true -> %{}
      end

    Enum.reject(required_fields, fn field ->
      not is_nil(get_path(value, String.split(field, ".")))
    end)
  end

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) -> value
      _other -> %{}
    end
  end

  defp missing_source_cues(_text, []), do: []

  defp missing_source_cues(text, required_source_cues) do
    normalized = normalize_text(text || "")

    Enum.reject(required_source_cues, fn cue ->
      String.contains?(normalized, normalize_text(cue))
    end)
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(value), do: normalize_text(to_string(value))

  defp artifact_quality(text) do
    section_bodies = section_bodies(text)
    map_dump_count = map_dump_count(text)

    issues =
      []
      |> maybe_risk(String.trim(text || "") == "", "artifact text was empty")
      |> maybe_risk(
        map_dump_count >= 2,
        "artifact appears to contain repeated raw map dumps"
      )
      |> maybe_risk(
        repeated_sections?(section_bodies),
        "artifact appears to repeat the same section body"
      )

    %{
      status: if(issues == [], do: :acceptable, else: :questionable),
      issues: issues,
      map_dump_count: map_dump_count,
      section_count: length(section_bodies),
      unique_section_body_count: unique_body_count(section_bodies)
    }
  end

  defp map_dump_count(text) do
    Regex.scan(~r/%\{[^}]+=>[^}]+\}/s, text || "")
    |> length()
  end

  defp section_bodies(text) do
    text
    |> to_string()
    |> String.split(~r/^\#{1,6}\s+.+$/m, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp repeated_sections?(section_bodies) do
    length(section_bodies) >= 3 and unique_body_count(section_bodies) < length(section_bodies)
  end

  defp unique_body_count(section_bodies) do
    section_bodies
    |> Enum.map(&normalize_text/1)
    |> Enum.uniq()
    |> length()
  end

  defp output_text(%{text: text}) when is_binary(text), do: text
  defp output_text(%{"text" => text}) when is_binary(text), do: text
  defp output_text(%{content: content}) when is_binary(content), do: content
  defp output_text(%{"content" => content}) when is_binary(content), do: content
  defp output_text(value) when is_binary(value), do: value
  defp output_text(_value), do: nil

  defp source_count(context) do
    context
    |> get(:sources, [])
    |> List.wrap()
    |> length()
  end

  defp provenance_count(value) when is_list(value),
    do: Enum.reduce(value, 0, &(&2 + provenance_count(&1)))

  defp provenance_count(value) when is_map(value) do
    own =
      value
      |> get(:provenance, [])
      |> case do
        provenance when is_list(provenance) -> length(provenance)
        _other -> 0
      end

    nested =
      value
      |> Map.take([:items, "items", :records, "records", :slices, "slices", :outputs, "outputs"])
      |> Map.values()
      |> Enum.reduce(0, &(&2 + provenance_count(&1)))

    own + nested
  end

  defp provenance_count(_value), do: 0

  defp residual_risks(
         :missing,
         _sections,
         _schema,
         _coverage,
         _text,
         _cues,
         _quality,
         _required?
       ),
       do: ["required artifact was not written"]

  defp residual_risks(
         _artifact_status,
         missing_sections,
         missing_schema,
         coverage_status,
         text,
         missing_source_cues,
         artifact_quality,
         require_artifact_quality?
       ) do
    []
    |> maybe_risk(String.trim(text || "") == "", "final output was empty")
    |> maybe_risk(
      missing_sections != [],
      "missing requested sections: #{Enum.join(missing_sections, ", ")}"
    )
    |> maybe_risk(
      missing_schema != [],
      "missing requested schema fields: #{Enum.join(missing_schema, ", ")}"
    )
    |> maybe_risk(
      coverage_status == :missing,
      "source/provenance coverage was required but not present"
    )
    |> maybe_risk(
      missing_source_cues != [],
      "missing required source cues: #{Enum.join(missing_source_cues, ", ")}"
    )
    |> maybe_risk(
      require_artifact_quality? and artifact_quality.status != :acceptable,
      "artifact quality issues: #{Enum.join(artifact_quality.issues, "; ")}"
    )
  end

  defp maybe_risk(risks, true, risk), do: risks ++ [risk]
  defp maybe_risk(risks, false, _risk), do: risks

  defp get_path(value, []), do: value
  defp get_path(nil, _path), do: nil

  defp get_path(value, [key | rest]) when is_map(value) do
    value
    |> get(key, nil)
    |> get_path(rest)
  end

  defp get_path(_value, _path), do: nil

  defp string_list(values),
    do: values |> List.wrap() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, Map.get(map, existing_atom_key(map, key), default))

  defp get(_map, _key, default), do: default

  defp existing_atom_key(map, key) do
    Enum.find(Map.keys(map), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end
end
