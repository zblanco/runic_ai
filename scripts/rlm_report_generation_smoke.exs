defmodule RunicAI.Manual.RLMReportGenerationSmoke do
  @moduledoc false

  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM
  alias RunicAI.RLM.LeafResult
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.Probe
  alias RunicAI.Steps.RLMMapLeaves
  alias RunicAI.Steps.RLMReduce

  @default_model "openai:gpt-5.4-mini"
  @default_chunk_size 1_800
  @default_overlap 180
  @default_output_tokens 1_100
  @gpt_54_mini_input_per_mtok 0.75
  @gpt_54_mini_output_per_mtok 4.50

  @sections [
    %{
      id: "objectives",
      title: "Project Objectives",
      depends_on: [],
      guidance:
        "State measurable project objectives and keep the client's operational continuity language.",
      markers: [
        :operational_continuity,
        :throughput,
        :spoilage,
        :wms
      ]
    },
    %{
      id: "technical_scope",
      title: "Technical Scope",
      depends_on: ["objectives"],
      guidance:
        "Describe the works by discipline, including security, electrical, commissioning, and controls interfaces.",
      markers: [
        :security,
        :cabling_conflict,
        :discipline_leads
      ]
    },
    %{
      id: "risks_interfaces",
      title: "Risks And Interfaces",
      depends_on: ["objectives", "technical_scope"],
      guidance:
        "Call out contradictions, operational risks, sequencing constraints, and dependencies between disciplines.",
      markers: [
        :cabling_conflict,
        :operational_continuity,
        :discipline_leads
      ]
    },
    %{
      id: "assumptions_exclusions",
      title: "Assumptions And Exclusions",
      depends_on: ["technical_scope"],
      guidance:
        "Use contractual phrasing. Include explicit exclusions and any definitions needed to read the report.",
      markers: [
        :exclusions,
        :definitions,
        :client_idioms
      ]
    },
    %{
      id: "executive_summary",
      title: "Executive Summary",
      depends_on: ["objectives", "technical_scope", "risks_interfaces", "assumptions_exclusions"],
      guidance:
        "Summarize the report after the dependent sections have been generated. Do not introduce new facts.",
      markers: [
        :operational_continuity,
        :throughput,
        :exclusions
      ]
    }
  ]

  @markers %{
    operational_continuity: [
      "operational continuity",
      "24 7 operations",
      "no unplanned shutdowns"
    ],
    throughput: [
      "9500 pallets",
      "9 500 pallets",
      "9500 pallet"
    ],
    spoilage: [
      "12%",
      "12 percent",
      "spoilage"
    ],
    wms: [
      "warehouse management system",
      "wms"
    ],
    security: [
      "42 ip cameras",
      "42 cameras",
      "badge access",
      "no biometric"
    ],
    cabling_conflict: [
      "cat6a",
      "single mode fiber",
      "external yard",
      "copper"
    ],
    discipline_leads: [
      "discipline lead",
      "electrical lead",
      "security lead"
    ],
    exclusions: [
      "ammonia refrigeration",
      "rail siding",
      "autonomous forklift"
    ],
    definitions: [
      "approved for construction",
      "geospatial information system",
      "contractual definitions"
    ],
    client_idioms: [
      "maintain operational continuity",
      "no unplanned shutdowns",
      "discipline lead sign off"
    ]
  }

  def main(argv) do
    config = parse_args(argv)
    ensure_live_ready!(config)
    model = model_for(config.model)

    {:ok, log} = Agent.start_link(fn -> [] end)
    task = report_task(config.task_size)

    runs =
      case config.mode do
        :direct -> [run_direct(config, task, model, log)]
        :rlm -> [run_rlm(config, task, model, log)]
        :both -> [run_direct(config, task, model, log), run_rlm(config, task, model, log)]
      end
      |> write_run_outputs(config.output)

    report = %{
      name: "rlm_report_generation_smoke",
      dry_run: config.dry_run?,
      model: config.model,
      mode: config.mode,
      generated_at_unix: System.system_time(:second),
      task: task_summary(task, config.sections),
      runs: runs,
      comparison: compare_runs(runs),
      notes: [
        "Adapted from report-generation tasks where the template is a dependency tree.",
        "The Runic RLM path uses deterministic split/map/reduce structure with bounded leaf LLM calls.",
        "Use dry_run=false only for manual provider-backed verification."
      ]
    }

    File.mkdir_p!(Path.dirname(config.output))
    File.write!(config.output, Jason.encode!(report, pretty: true))

    print_summary(report, config.output)
  end

  defp parse_args(argv) do
    argv = drop_leading_separator(argv)

    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          chunk_size: :integer,
          dry_run: :boolean,
          live: :boolean,
          max_tokens: :integer,
          mode: :string,
          model: :string,
          output: :string,
          overlap: :integer,
          reasoning_effort: :string,
          section: :keep,
          task_size: :string
        ],
        aliases: [m: :model, o: :output]
      )

    if invalid != [] do
      raise ArgumentError, "unknown options: #{inspect(invalid)}"
    end

    live? = Keyword.get(opts, :live, false) or truthy?(System.get_env("RUNIC_AI_RLM_LIVE"))
    dry_run? = Keyword.get(opts, :dry_run, false) or not live?

    %{
      chunk_size: Keyword.get(opts, :chunk_size, @default_chunk_size),
      dry_run?: dry_run?,
      live?: live? and not dry_run?,
      max_tokens: Keyword.get(opts, :max_tokens, @default_output_tokens),
      mode: opts |> Keyword.get(:mode, "both") |> parse_mode(),
      model: Keyword.get(opts, :model, System.get_env("RUNIC_AI_RLM_MODEL") || @default_model),
      output:
        Keyword.get(
          opts,
          :output,
          "tmp/rlm_report_generation_smoke_#{System.system_time(:second)}.json"
        ),
      overlap: Keyword.get(opts, :overlap, @default_overlap),
      reasoning_effort:
        opts |> Keyword.get(:reasoning_effort, "none") |> parse_reasoning_effort(),
      sections: opts |> Keyword.get_values(:section) |> select_sections(),
      task_size: opts |> Keyword.get(:task_size, "small") |> parse_task_size()
    }
  end

  defp parse_mode("both"), do: :both
  defp parse_mode("direct"), do: :direct
  defp parse_mode("rlm"), do: :rlm

  defp parse_mode(other) do
    raise ArgumentError, "--mode must be one of: both, direct, rlm; got #{inspect(other)}"
  end

  defp parse_reasoning_effort("none"), do: :none
  defp parse_reasoning_effort("minimal"), do: :minimal
  defp parse_reasoning_effort("low"), do: :low
  defp parse_reasoning_effort("medium"), do: :medium
  defp parse_reasoning_effort("high"), do: :high
  defp parse_reasoning_effort("xhigh"), do: :xhigh
  defp parse_reasoning_effort("default"), do: :default
  defp parse_reasoning_effort(value) when is_atom(value), do: value

  defp parse_reasoning_effort(other) do
    raise ArgumentError,
          "--reasoning-effort must be none, minimal, low, medium, high, xhigh, or default; got #{inspect(other)}"
  end

  defp parse_task_size("small"), do: :small
  defp parse_task_size("medium"), do: :medium
  defp parse_task_size("large"), do: :large

  defp parse_task_size(other) do
    raise ArgumentError, "--task-size must be one of: small, medium, large; got #{inspect(other)}"
  end

  defp select_sections([]), do: @sections

  defp select_sections(values) do
    ids =
      values
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    sections = Enum.filter(@sections, &(&1.id in ids))
    selected_ids = Enum.map(sections, & &1.id)
    unknown = ids -- selected_ids

    if unknown != [] do
      raise ArgumentError, "unknown section ids: #{Enum.join(unknown, ", ")}"
    end

    sections
  end

  defp ensure_live_ready!(%{dry_run?: true}), do: :ok

  defp ensure_live_ready!(%{model: "openai:" <> _}) do
    unless present?(System.get_env("OPENAI_API_KEY")) do
      raise """
      RUNIC_AI_RLM_LIVE requested an OpenAI model, but OPENAI_API_KEY is not set.

      Example:
        RUNIC_AI_RLM_LIVE=1 OPENAI_API_KEY=sk-... mix run scripts/rlm_report_generation_smoke.exs --mode both
      """
    end
  end

  defp ensure_live_ready!(_config), do: :ok

  defp model_for("openai:" <> model_id) do
    ReqLLM.model!(%{
      provider: :openai,
      id: model_id,
      provider_model_id: model_id
    })
  end

  defp model_for(model), do: model

  defp output_token_opts(%{model: "openai:" <> model_id}, tokens) do
    if openai_reasoning_model?(model_id) do
      [max_completion_tokens: tokens]
    else
      [max_tokens: tokens]
    end
  end

  defp output_token_opts(_config, tokens), do: [max_tokens: tokens]

  defp openai_reasoning_model?(model_id) do
    String.starts_with?(model_id, "gpt-5") or String.starts_with?(model_id, "gpt-4.1") or
      String.starts_with?(model_id, "o1") or String.starts_with?(model_id, "o3") or
      String.starts_with?(model_id, "o4")
  end

  defp put_default_output_tokens(opts, config) do
    if Keyword.has_key?(opts, :max_tokens) or Keyword.has_key?(opts, :max_completion_tokens) do
      opts
    else
      Keyword.merge(opts, output_token_opts(config, config.max_tokens))
    end
  end

  defp output_token_limit(opts) do
    Keyword.get(opts, :max_tokens) || Keyword.get(opts, :max_completion_tokens) ||
      @default_output_tokens
  end

  defp run_direct(config, task, model, log) do
    started = monotonic_ms()

    call =
      call_text!(
        config,
        model,
        direct_prompt(task, config.sections),
        output_token_opts(config, max(config.max_tokens * length(config.sections), 1_800)),
        %{method: "direct", phase: "generate", section: "report"},
        log
      )

    output = call.text
    calls = calls_for(log, "direct")

    %{
      method: "direct",
      elapsed_ms: monotonic_ms() - started,
      output: output,
      output_chars: String.length(output),
      output_preview: String.slice(output, 0, 1_200),
      score: score_report(output, config.sections),
      calls: summarize_calls(calls, config),
      call_estimate: %{estimated_total_calls: 1, actual_total_calls: length(calls)}
    }
  end

  defp run_rlm(config, task, model, log) do
    started = monotonic_ms()
    {:ok, environment} = RLM.init_environment(metadata: %{task: "manual_rlm_report_generation"})
    {environment, source_refs} = put_sources(environment, task.sources)
    total_slices = count_slices(environment, source_refs, config)

    probes = Enum.map(source_refs, &Probe.new!(&1, &1.metadata.size))

    policy =
      Policy.new!(
        leaf_window: config.chunk_size,
        max_depth: 2,
        max_branching_factor: length(source_refs),
        max_leaf_calls: total_slices * length(config.sections),
        max_reduce_calls: length(config.sections),
        max_estimated_tokens: nil,
        metadata: %{task_shape: :report_generation}
      )

    {:ok, plan} = RLM.plan(:report_generation, source_refs, policy: policy, probes: probes)

    completed =
      Enum.reduce(config.sections, %{}, fn section, acc ->
        leaf_results = extract_section(config, model, environment, source_refs, section, log)
        reduction = compose_section(config, model, section, leaf_results, acc, log)
        Map.put(acc, section.id, reduction.output)
      end)

    output = assemble_report(config.sections, completed)
    calls = calls_for(log, "runic_rlm")

    %{
      method: "runic_rlm",
      elapsed_ms: monotonic_ms() - started,
      output: output,
      output_chars: String.length(output),
      output_preview: String.slice(output, 0, 1_200),
      score: score_report(output, config.sections),
      section_reviews: review_sections(config.sections, completed),
      calls: summarize_calls(calls, config),
      call_estimate: %{
        default_plan_leaf_calls: plan.cost_estimate.leaf_calls,
        expanded_extract_calls: total_slices * length(config.sections),
        expanded_compose_calls: length(config.sections),
        estimated_total_calls: total_slices * length(config.sections) + length(config.sections),
        actual_total_calls: length(calls),
        exact_match:
          length(calls) == total_slices * length(config.sections) + length(config.sections)
      }
    }
  end

  defp put_sources(environment, sources) do
    Enum.reduce(sources, {environment, []}, fn source, {environment, refs} ->
      {:ok, ref, environment} =
        RLM.put_source(environment, source.text,
          id: source.id,
          label: source.label,
          metadata: %{kind: source.kind}
        )

      {environment, [ref | refs]}
    end)
    |> then(fn {environment, refs} -> {environment, Enum.reverse(refs)} end)
  end

  defp count_slices(environment, source_refs, config) do
    source_refs
    |> Enum.map(fn source_ref ->
      {:ok, slice_set} =
        RLM.split(environment, source_ref, chunk_size: config.chunk_size, overlap: config.overlap)

      length(slice_set.slices)
    end)
    |> Enum.sum()
  end

  defp extract_section(config, model, environment, source_refs, section, log) do
    Enum.flat_map(source_refs, fn source_ref ->
      {:ok, slice_set} =
        RLM.split(environment, source_ref, chunk_size: config.chunk_size, overlap: config.overlap)

      {:ok, artifacts} = RLM.materialize(environment, slice_set)

      mapper = fn artifact ->
        call =
          call_text!(
            config,
            model,
            extract_prompt(section, source_ref, artifact),
            output_token_opts(config, min(config.max_tokens, 900)),
            %{
              method: "runic_rlm",
              phase: "extract",
              section: section.id,
              source: source_ref.source_id,
              artifact: artifact.id
            },
            log
          )

        LeafResult.new!(
          %{
            section_id: section.id,
            source_id: source_ref.source_id,
            artifact_id: artifact.id,
            text: call.text
          },
          id: "leaf:#{section.id}:#{artifact.id}",
          artifact: artifact,
          usage: call.usage,
          metadata: %{
            phase: :extract,
            section_id: section.id,
            source_id: source_ref.source_id,
            latency_ms: call.latency_ms
          }
        )
      end

      {:ok, leaf_results} = RLMMapLeaves.map_artifacts(artifacts, mapper)
      leaf_results
    end)
  end

  defp compose_section(config, model, section, leaf_results, completed_sections, log) do
    reducer = fn leaf_results ->
      call =
        call_text!(
          config,
          model,
          compose_prompt(section, leaf_results, completed_sections),
          output_token_opts(config, config.max_tokens),
          %{method: "runic_rlm", phase: "compose", section: section.id},
          log
        )

      %{
        section_id: section.id,
        title: section.title,
        text: call.text,
        usage: call.usage,
        latency_ms: call.latency_ms,
        extraction_count: length(leaf_results)
      }
    end

    {:ok, reduction} = RLMReduce.reduce(leaf_results, reducer)
    reduction
  end

  defp call_text!(config, model, prompt, call_opts, label, log) do
    started = monotonic_ms()

    call_opts =
      call_opts
      |> Keyword.put_new(:reasoning_effort, config.reasoning_effort)
      |> put_default_output_tokens(config)

    result =
      if config.dry_run? do
        {:ok,
         %{
           text: dry_text(label, prompt),
           usage: estimate_dry_usage(prompt, output_token_limit(call_opts)),
           finish_reason: :dry_run
         }}
      else
        case LLM.generate_text(model, prompt, call_opts) do
          {:ok, %Result{} = result} ->
            {:ok,
             %{
               text: Result.text(result),
               usage: result.usage || %{},
               finish_reason: result.finish_reason
             }}

          {:error, error} ->
            {:error, error}
        end
      end

    latency_ms = monotonic_ms() - started

    case result do
      {:ok, call} ->
        record_call(
          log,
          Map.merge(label, %{
            latency_ms: latency_ms,
            usage: call.usage,
            finish_reason: call.finish_reason
          })
        )

        Map.put(call, :latency_ms, latency_ms)

      {:error, error} ->
        record_call(log, Map.merge(label, %{latency_ms: latency_ms, error: inspect(error)}))
        raise "LLM call failed for #{inspect(label)}: #{inspect(error)}"
    end
  end

  defp record_call(log, call) do
    Agent.update(log, fn calls -> [call | calls] end)
  end

  defp calls_for(log, method) do
    log
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.method == method))
  end

  defp summarize_calls(calls, config) do
    usage = Enum.reduce(calls, %{}, &merge_usage/2)
    input_tokens = usage_value(usage, [:input_tokens, :prompt_tokens, :input])
    output_tokens = usage_value(usage, [:output_tokens, :completion_tokens, :output])

    %{
      count: length(calls),
      phases: Enum.frequencies_by(calls, & &1.phase),
      finish_reasons:
        calls
        |> Enum.map(&(Map.get(&1, :finish_reason) || :unknown))
        |> Enum.map(&to_string/1)
        |> Enum.frequencies(),
      latency_ms: Enum.sum(Enum.map(calls, &Map.get(&1, :latency_ms, 0))),
      usage: usage,
      estimated_cost_usd: estimate_cost(config.model, input_tokens, output_tokens)
    }
  end

  defp merge_usage(call, acc) do
    call
    |> Map.get(:usage, %{})
    |> Enum.reduce(acc, fn {key, value}, acc ->
      if is_number(value) do
        Map.update(acc, key, value, &(&1 + value))
      else
        acc
      end
    end)
  end

  defp usage_value(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
    end)
  end

  defp estimate_cost("openai:gpt-5.4-mini", input_tokens, output_tokens)
       when is_number(input_tokens) and is_number(output_tokens) do
    Float.round(
      input_tokens / 1_000_000 * @gpt_54_mini_input_per_mtok +
        output_tokens / 1_000_000 * @gpt_54_mini_output_per_mtok,
      6
    )
  end

  defp estimate_cost(_model, _input_tokens, _output_tokens), do: nil

  defp direct_prompt(task, sections) do
    """
    You are writing a concise scope-of-works report from source material.

    Produce these sections, in order:
    #{section_list(sections)}

    Requirements:
    - Use only the supplied source material.
    - Preserve client-specific construction idioms where present.
    - Include contradictions, assumptions, exclusions, and definitions when relevant.
    - Mention source labels inline in parentheses when a fact is important.

    Source material:
    #{source_blob(task.sources)}
    """
  end

  defp extract_prompt(section, source_ref, artifact) do
    """
    You are a bounded leaf extractor in a deterministic RLM report-generation pipeline.

    Target section:
    #{section.title}

    Section guidance:
    #{section.guidance}

    Extract only facts from this bounded source slice that help write the target section.
    Include provenance as #{source_ref.source_id}/#{artifact.id}.
    If the slice has no relevant facts, say "NO_RELEVANT_FACTS".

    Source slice:
    #{artifact.content}
    """
  end

  defp compose_prompt(section, leaf_results, completed_sections) do
    """
    You are composing one report section from bounded extractions.

    Section:
    #{section.title}

    Writing guidance:
    #{section.guidance}

    Dependency context:
    #{dependency_context(section, completed_sections)}

    Extracted facts:
    #{leaf_fact_blob(leaf_results)}

    Write the section in concise professional prose.
    Return only the section body; do not repeat the markdown heading.
    Keep the content focused on this section's guidance, even when other extracted facts are visible.
    Use only the extracted facts and dependency context.
    If a required fact is missing, name the gap plainly instead of inventing it.
    """
  end

  defp assemble_report(sections, completed) do
    sections
    |> Enum.map(fn section ->
      output = Map.fetch!(completed, section.id)
      "## #{section.title}\n\n#{output.text}"
    end)
    |> Enum.join("\n\n")
  end

  defp dependency_context(%{depends_on: []}, _completed), do: "No dependency sections."

  defp dependency_context(section, completed) do
    section.depends_on
    |> Enum.map(fn section_id ->
      case Map.get(completed, section_id) do
        nil -> "- #{section_id}: not generated yet"
        output -> "- #{output.title}: #{output.text}"
      end
    end)
    |> Enum.join("\n")
  end

  defp leaf_fact_blob(leaf_results) do
    leaf_results
    |> Enum.map(fn result ->
      "- #{result.output.source_id}/#{result.output.artifact_id}: #{result.output.text}"
    end)
    |> Enum.join("\n")
  end

  defp section_list(sections) do
    sections
    |> Enum.map(fn section ->
      dependencies =
        case section.depends_on do
          [] -> "none"
          ids -> Enum.join(ids, ", ")
        end

      "- #{section.title} (depends on: #{dependencies}): #{section.guidance}"
    end)
    |> Enum.join("\n")
  end

  defp source_blob(sources) do
    sources
    |> Enum.map(fn source ->
      """
      [#{source.id}] #{source.label}
      #{source.text}
      """
    end)
    |> Enum.join("\n")
  end

  defp review_sections(sections, completed) do
    Enum.map(sections, fn section ->
      output = Map.fetch!(completed, section.id)
      score = score_text(output.text, section.markers)

      %{
        section_id: section.id,
        title: section.title,
        expected_markers: section.markers,
        score: score
      }
    end)
  end

  defp score_report(text, sections) do
    marker_ids =
      sections
      |> Enum.flat_map(& &1.markers)
      |> Enum.uniq()

    score_text(text, marker_ids)
  end

  defp score_text(text, marker_ids) do
    normalized = normalize_text(text)

    results =
      Enum.map(marker_ids, fn marker_id ->
        alternatives = Map.fetch!(@markers, marker_id)
        hit? = Enum.any?(alternatives, &String.contains?(normalized, normalize_text(&1)))
        {marker_id, hit?}
      end)

    hits =
      results
      |> Enum.filter(fn {_id, hit?} -> hit? end)
      |> Enum.map(fn {id, _hit?} -> id end)

    missing =
      results
      |> Enum.reject(fn {_id, hit?} -> hit? end)
      |> Enum.map(fn {id, _hit?} -> id end)

    %{
      hits: hits,
      missing: missing,
      hit_count: length(hits),
      total: length(results),
      ratio: Float.round(length(hits) / max(length(results), 1), 3)
    }
  end

  defp normalize_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9%]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp compare_runs(runs) do
    by_method = Map.new(runs, &{&1.method, &1})

    case {Map.get(by_method, "direct"), Map.get(by_method, "runic_rlm")} do
      {%{} = direct, %{} = rlm} ->
        %{
          direct_score_ratio: direct.score.ratio,
          runic_rlm_score_ratio: rlm.score.ratio,
          score_delta: Float.round(rlm.score.ratio - direct.score.ratio, 3),
          direct_calls: direct.calls.count,
          runic_rlm_calls: rlm.calls.count,
          runic_rlm_call_estimate_exact: rlm.call_estimate.exact_match
        }

      _ ->
        %{}
    end
  end

  defp write_run_outputs(runs, output_path) do
    output_root = Path.rootname(output_path)
    File.mkdir_p!(Path.dirname(output_path))

    Enum.map(runs, fn run ->
      path = "#{output_root}_#{run.method}.md"

      File.write!(path, """
      # #{run.method} Report Output

      Generated by `scripts/rlm_report_generation_smoke.exs`.

      - score: #{run.score.hit_count}/#{run.score.total}
      - calls: #{run.calls.count}
      - elapsed_ms: #{run.elapsed_ms}
      - estimated_cost_usd: #{inspect(run.calls.estimated_cost_usd)}

      #{run.output}
      """)

      Map.put(run, :output_path, path)
    end)
  end

  defp task_summary(task, sections) do
    %{
      name: task.name,
      size: task.size,
      source_count: length(task.sources),
      source_chars: Enum.map(task.sources, &%{id: &1.id, chars: String.length(&1.text)}),
      sections: Enum.map(sections, &Map.take(&1, [:id, :title, :depends_on]))
    }
  end

  defp print_summary(report, output_path) do
    IO.puts("\nRLM report-generation smoke complete")
    IO.puts("  output: #{output_path}")
    IO.puts("  dry_run: #{report.dry_run}")
    IO.puts("  model: #{report.model}")

    Enum.each(report.runs, fn run ->
      IO.puts(
        "  #{run.method}: score #{run.score.hit_count}/#{run.score.total}, calls #{run.calls.count}, elapsed #{run.elapsed_ms}ms"
      )
    end)

    if report.comparison != %{} do
      IO.puts(
        "  score_delta(runic_rlm - direct): #{report.comparison.score_delta}; call estimate exact: #{report.comparison.runic_rlm_call_estimate_exact}"
      )
    end
  end

  defp dry_text(%{method: "direct", phase: "generate"}, prompt) do
    """
    DRY DIRECT REPORT

    This dry run echoes the task shape without calling a provider.
    #{String.slice(prompt, 0, 1_500)}
    """
  end

  defp dry_text(%{phase: "extract", section: section, source: source}, prompt) do
    """
    DRY EXTRACT #{section}/#{source}
    #{String.slice(prompt, 0, 700)}
    """
  end

  defp dry_text(%{phase: "compose", section: section}, prompt) do
    """
    DRY COMPOSE #{section}
    #{String.slice(prompt, 0, 1_000)}
    """
  end

  defp estimate_dry_usage(prompt, max_tokens) do
    input_tokens = div(String.length(prompt) + 3, 4)
    output_tokens = min(max_tokens || @default_output_tokens, 300)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  defp report_task(size) do
    task = %{
      name: "north_pier_scope_of_works",
      size: size,
      sources: [
        %{
          id: "brief",
          label: "Client project brief",
          kind: :brief,
          text: """
          North Pier Logistics Hub is expanding its cold-chain processing hall while maintaining 24/7 operations.
          The client objective is to maintain operational continuity with no unplanned shutdowns during the 18-month construction phase.
          The expansion must reduce spoilage losses by 12 percent and increase throughput to 9,500 pallets per day.
          The works must integrate with the existing WMS, the warehouse management system used for pallet tracking and dispatch.
          The client wants a scope-of-works report, not a fee proposal, and requires project objectives to be stated explicitly.
          """
        },
        %{
          id: "technical_spec",
          label: "Electrical and security technical specification",
          kind: :technical_spec,
          text: """
          Security scope includes 42 IP cameras, badge access at five controlled doors, and no biometric access control.
          The internal security network shall use CAT6A cabling back to the local equipment racks.
          Yard cameras along the external route shall use single-mode fiber because copper cabling is excluded outside the building envelope.
          Electrical shutdowns are permitted only in approved four-hour windows and require electrical lead sign-off.
          Commissioning must include camera coverage testing, access-control failover testing, and WMS interface testing.
          """
        },
        %{
          id: "discipline_notes",
          label: "Discipline lead notes and commercial exclusions",
          kind: :discipline_notes,
          text: """
          Use the client's idiom "maintain operational continuity" when describing sequencing and staging.
          Discipline lead sign-off is required from electrical, security, controls, and operations before AFC issue.
          Contractual definitions: AFC means Approved For Construction; GIS means Geospatial Information System; PC means Practical Completion.
          Exclusions: ammonia refrigeration plant replacement, rail siding works, and autonomous forklift procurement are outside this scope.
          Security lead notes warn that the CAT6A and single-mode fiber split must be made explicit to avoid a cabling contradiction.
          """
        }
      ]
    }

    %{
      task
      | name: "#{task.name}_#{size}",
        sources: Enum.map(task.sources, &expand_source(&1, size))
    }
  end

  defp expand_source(source, :small), do: source

  defp expand_source(source, :medium) do
    %{source | text: source.text <> "\n\n" <> Map.fetch!(medium_appendices(), source.id)}
  end

  defp expand_source(source, :large) do
    %{
      source
      | text:
          source.text <>
            "\n\n" <>
            Map.fetch!(medium_appendices(), source.id) <>
            "\n\n" <>
            Map.fetch!(large_appendices(), source.id)
    }
  end

  defp medium_appendices do
    %{
      "brief" => """
      Client workshop minutes add that the existing dispatch yard cannot lose more than one loading bay during any weekday shift.
      The north dock must remain available for chilled goods, and any temporary lane closure needs 72 hours notice to operations.
      The client defines success as keeping customer order fill-rate above 98.5 percent during construction while the cold-chain hall is extended.
      There is a temporary works preference for night-shift hoarding moves because daytime forklift routes are already near capacity.
      The operations director asked for weekly readiness checkpoints, each signed by the operations lead, controls lead, and construction manager.
      The WMS integration must preserve barcode scan events, pallet exception codes, and dispatch timestamp audit fields.
      A project objective is to complete practical completion before the October peak season freeze period.
      The report should avoid sales language and keep the tone contractual, measurable, and suitable for discipline lead review.
      """,
      "technical_spec" => """
      Electrical distribution for the security cabinets shall be backed by the existing essential services board.
      UPS autonomy is required for 45 minutes at each local equipment rack.
      The controls interface shall emit door-held-open, camera-health, and WMS dispatch-block events to the site supervisor dashboard.
      External yard camera poles require lightning protection bonding and coordination with civil drainage routes.
      The specification repeats that copper cabling is not permitted outside the building envelope, while internal camera runs may use CAT6A.
      Fire alarm interfaces are monitoring-only; no fire alarm cause-and-effect changes are included in this scope.
      Commissioning evidence shall include annotated camera screenshots, access-control failover logs, and WMS message trace exports.
      The technical scope should separate construction works, systems integration, testing, and handover deliverables.
      """,
      "discipline_notes" => """
      Discipline review notes require the scope to name each sign-off gate: design freeze, AFC issue, installation readiness, commissioning readiness, and practical completion.
      The electrical lead owns shutdown window approvals and UPS calculations.
      The security lead owns camera schedule acceptance, access-control door list acceptance, and the CAT6A versus fiber boundary statement.
      The controls lead owns WMS message mapping and dashboard event validation.
      The operations lead owns staging acceptance, lane closure notices, and order fill-rate monitoring.
      Commercial assumptions include normal working access except for nominated night-shift hoarding changes.
      Commercial exclusions include ammonia refrigeration plant replacement, rail siding works, autonomous forklift procurement, and any change to fire alarm cause-and-effect.
      The client idiom "maintain operational continuity" should appear in objectives, risks, and executive summary sections.
      """
    }
  end

  defp large_appendices do
    %{
      "brief" => """
      The client risk register records three operational risks: loss of chilled dispatch capacity, WMS cutover instability, and poor handover readiness for peak season.
      Mitigations include phased hoarding, mock WMS message replay before live cutover, and a joint practical completion checklist.
      The existing warehouse operates with two overlapping shifts, so noisy works beside the north dock require shift-manager approval.
      A supplementary objective is to preserve cold-chain compliance records during construction, including temperature excursion evidence and dispatch audit history.
      The final report should make clear that the contractor is responsible for coordination of temporary works, but the client remains responsible for approving operational shutdown windows.
      """,
      "technical_spec" => """
      Network cabinets shall be labelled with rack, switch, UPS, and patch-panel references before commissioning starts.
      The technical specification requires red-line drawings within five business days of installation completion for each workface.
      Integration testing shall use a witnessed test script and record pass, fail, retest, and concession status for each camera, door, and WMS event.
      The single-mode fiber backbone for external yard cameras must include spare cores for future expansion, but future cameras are excluded from this scope.
      The report should flag that the cabling rule is not a contradiction if the internal and external boundaries are stated clearly.
      """,
      "discipline_notes" => """
      Reviewers asked that assumptions and exclusions be separated from technical scope so commercial boundaries do not get lost in construction prose.
      Definitions requested for AFC, GIS, PC, WMS, UPS, and operational continuity.
      The executive summary should mention the October peak season freeze period, the 98.5 percent fill-rate target, and the no-unplanned-shutdown requirement.
      The risks section should include a cross-discipline consistency check for security cabling, shutdown windows, WMS messaging, and commissioning evidence.
      The final report should state that unresolved contradictions are to be raised as requests for information before AFC issue.
      """
    }
  end

  defp truthy?(value) when value in ["1", "true", "TRUE", "yes", "YES"], do: true
  defp truthy?(_), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp drop_leading_separator(["--" | rest]), do: rest
  defp drop_leading_separator(argv), do: argv

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

RunicAI.Manual.RLMReportGenerationSmoke.main(System.argv())
