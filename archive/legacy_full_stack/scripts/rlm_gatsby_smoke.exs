defmodule RunicAI.Manual.RLMGatsbySmoke do
  @moduledoc false

  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.RLM
  alias RunicAI.RLM.LeafResult
  alias RunicAI.RLM.Policy
  alias RunicAI.RLM.Probe
  alias RunicAI.Steps.RLMMapLeaves

  @default_model "openai:gpt-5.4-mini"
  @default_source_url "https://www.gutenberg.org/cache/epub/64317/pg64317.txt"
  @default_source_path "tmp/gatsby_pg64317_raw.txt"
  @default_chunk_size 9_000
  @default_overlap 500
  @default_concurrency 4
  @gpt_54_mini_input_per_mtok 0.75
  @gpt_54_mini_output_per_mtok 4.50
  @roman_line ~r/^\s*M{0,4}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})\s*$/u

  @report_markers %{
    green_light: ["green light"],
    valley_of_ashes: ["valley of ashes"],
    eckleburg: ["eckleburg", "eyes of doctor t j eckleburg", "eyes of dr t j eckleburg"],
    east_west_egg: ["east egg", "west egg"],
    american_dream: ["american dream"],
    past_time: ["past", "time", "repeat the past"],
    cars: ["car", "automobile", "motor"],
    weather: ["weather", "rain", "heat", "season"],
    shirts_wealth: ["shirts", "wealth"],
    citations: ["\"", "chapter"]
  }

  def main(argv) do
    config = parse_args(argv)
    ensure_live_ready!(config)
    model = model_for(config.model)
    {:ok, log} = Agent.start_link(fn -> [] end)

    started = monotonic_ms()
    raw_text = load_source!(config)
    text = trim_gutenberg(raw_text)
    chapters = split_by_roman_chapters(text, config.max_chapters)
    {:ok, environment} = RLM.init_environment(metadata: %{task: "gatsby_rlm_smoke"})
    {environment, chapter_refs} = put_chapters(environment, chapters)
    chapter_slices = split_chapters(environment, chapter_refs, config)

    policy =
      Policy.new!(
        leaf_window: config.chunk_size,
        max_depth: 2,
        max_branching_factor: length(chapter_refs),
        max_leaf_calls: slice_count(chapter_slices),
        max_reduce_calls: length(chapter_refs) + 2,
        max_estimated_tokens: nil,
        metadata: %{task_shape: :gatsby_metaphor_report}
      )

    source_refs = Enum.map(chapter_refs, fn {_chapter, ref} -> ref end)
    probes = Enum.map(source_refs, &Probe.new!(&1, &1.metadata.size))
    {:ok, plan} = RLM.plan(:analysis, source_refs, policy: policy, probes: probes)

    evidence = extract_evidence(config, model, environment, chapter_slices, log)
    chapter_analyses = compose_chapter_analyses(config, model, chapters, evidence, log)
    overall_analysis = compose_overall_analysis(config, model, chapter_analyses, log)

    metaphor_report =
      compose_metaphor_report(config, model, overall_analysis, chapter_analyses, log)

    executive_summary = compose_executive_summary(config, model, metaphor_report, log)

    translations =
      translate_outputs(
        config,
        model,
        %{metaphor_report: metaphor_report, executive_summary: executive_summary},
        log
      )

    calls = Agent.get(log, &Enum.reverse/1)
    outputs = output_paths(config.output)

    artifacts = %{
      metaphor_report: metaphor_report,
      executive_summary: executive_summary,
      spanish_metaphor_report: translations.spanish_metaphor_report,
      mandarin_metaphor_report: translations.mandarin_metaphor_report,
      spanish_executive_summary: translations.spanish_executive_summary,
      mandarin_executive_summary: translations.mandarin_executive_summary,
      chapter_analyses: chapter_analyses_markdown(chapter_analyses),
      evidence: evidence_markdown(evidence)
    }

    write_artifacts!(outputs, artifacts)

    result = %{
      name: "rlm_gatsby_smoke",
      dry_run: config.dry_run?,
      model: config.model,
      generated_at_unix: System.system_time(:second),
      elapsed_ms: monotonic_ms() - started,
      source: %{
        url: config.source_url,
        cache_path: config.source_path,
        raw_chars: String.length(raw_text),
        trimmed_chars: String.length(text)
      },
      json_output_path: config.output,
      task: %{
        title: "The Great Gatsby",
        chapter_count: length(chapters),
        chapter_chars:
          Enum.map(chapters, fn {chapter, text} ->
            %{chapter: chapter, chars: String.length(text)}
          end),
        slice_count: slice_count(chapter_slices),
        outputs: Map.keys(artifacts)
      },
      rlm_plan: %{
        default_plan_leaf_calls: plan.cost_estimate.leaf_calls,
        expanded_extract_calls: slice_count(chapter_slices),
        chapter_analysis_calls: length(chapters),
        compose_calls: 3,
        translation_calls: 4,
        estimated_total_calls: estimated_total_calls(chapters, chapter_slices),
        actual_total_calls: length(calls),
        exact_match: length(calls) == estimated_total_calls(chapters, chapter_slices)
      },
      score: score_report(metaphor_report),
      calls: summarize_calls(calls, config),
      artifact_metrics: artifact_metrics(artifacts),
      output_paths: outputs
    }

    File.mkdir_p!(Path.dirname(config.output))
    File.write!(config.output, Jason.encode!(result, pretty: true))

    print_summary(result)
  end

  defp parse_args(argv) do
    argv = drop_leading_separator(argv)

    {opts, _args, invalid} =
      OptionParser.parse(argv,
        switches: [
          chapter_tokens: :integer,
          chunk_size: :integer,
          concurrency: :integer,
          dry_run: :boolean,
          essay_tokens: :integer,
          evidence_tokens: :integer,
          live: :boolean,
          max_chapters: :integer,
          model: :string,
          output: :string,
          overlap: :integer,
          source_path: :string,
          source_url: :string,
          summary_tokens: :integer,
          translation_tokens: :integer
        ],
        aliases: [m: :model, o: :output]
      )

    if invalid != [] do
      raise ArgumentError, "unknown options: #{inspect(invalid)}"
    end

    live? = Keyword.get(opts, :live, false) or truthy?(System.get_env("RUNIC_AI_RLM_LIVE"))
    dry_run? = Keyword.get(opts, :dry_run, false) or not live?

    %{
      chapter_tokens: Keyword.get(opts, :chapter_tokens, 900),
      chunk_size: Keyword.get(opts, :chunk_size, @default_chunk_size),
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
      dry_run?: dry_run?,
      essay_tokens: Keyword.get(opts, :essay_tokens, 5_000),
      evidence_tokens: Keyword.get(opts, :evidence_tokens, 450),
      live?: live? and not dry_run?,
      max_chapters: Keyword.get(opts, :max_chapters),
      model: Keyword.get(opts, :model, System.get_env("RUNIC_AI_RLM_MODEL") || @default_model),
      output:
        Keyword.get(
          opts,
          :output,
          "tmp/rlm_gatsby_smoke_#{System.system_time(:second)}.json"
        ),
      overlap: Keyword.get(opts, :overlap, @default_overlap),
      source_path: Keyword.get(opts, :source_path, @default_source_path),
      source_url: Keyword.get(opts, :source_url, @default_source_url),
      summary_tokens: Keyword.get(opts, :summary_tokens, 350),
      translation_tokens: Keyword.get(opts, :translation_tokens, 7_000)
    }
  end

  defp ensure_live_ready!(%{dry_run?: true}), do: :ok

  defp ensure_live_ready!(%{model: "openai:" <> _}) do
    unless present?(System.get_env("OPENAI_API_KEY")) do
      raise "RUNIC_AI_RLM_LIVE requested an OpenAI model, but OPENAI_API_KEY is not set."
    end
  end

  defp ensure_live_ready!(_config), do: :ok

  defp load_source!(config) do
    if File.exists?(config.source_path) do
      File.read!(config.source_path)
    else
      response = Req.get!(config.source_url)
      File.mkdir_p!(Path.dirname(config.source_path))
      File.write!(config.source_path, response.body)
      response.body
    end
  end

  defp trim_gutenberg(text) do
    text
    |> trim_after("*** START OF THE PROJECT GUTENBERG EBOOK THE GREAT GATSBY ***")
    |> trim_before("*** END OF THE PROJECT GUTENBERG EBOOK THE GREAT GATSBY ***")
    |> String.trim()
  end

  defp trim_after(text, marker) do
    case :binary.match(text, marker) do
      {start, length} -> binary_part(text, start + length, byte_size(text) - start - length)
      :nomatch -> text
    end
  end

  defp trim_before(text, marker) do
    case :binary.match(text, marker) do
      {start, _length} -> binary_part(text, 0, start)
      :nomatch -> text
    end
  end

  defp split_by_roman_chapters(text, max_chapters) do
    text
    |> split_by_roman_chapters()
    |> Enum.reject(fn {_chapter, chapter_text} -> String.length(chapter_text) < 1_000 end)
    |> Enum.sort_by(fn {chapter, _text} -> chapter end)
    |> maybe_take(max_chapters)
  end

  defp split_by_roman_chapters(text) when is_binary(text) do
    lines = String.split(text, ~r/\R/u, trim: false)

    {chunks, current_num, current_lines} =
      Enum.reduce(lines, {[], 0, []}, fn line, {acc, num, buf} ->
        trimmed = String.trim(line)

        if trimmed != "" and Regex.match?(@roman_line, trimmed) do
          acc =
            case {num, buf} do
              {0, _buf} -> acc
              {_chapter, []} -> acc
              _ -> [{num, Enum.join(Enum.reverse(buf), "\n")} | acc]
            end

          {acc, roman_to_int!(trimmed), []}
        else
          {acc, num, [line | buf]}
        end
      end)

    chunks =
      case {current_num, current_lines} do
        {0, _lines} -> chunks
        {_chapter, []} -> chunks
        _ -> [{current_num, Enum.join(Enum.reverse(current_lines), "\n")} | chunks]
      end

    Enum.reverse(chunks)
  end

  defp roman_to_int!(roman) do
    roman
    |> String.trim()
    |> String.upcase()
    |> String.graphemes()
    |> Enum.map(&roman_value/1)
    |> Enum.reduce({0, 0}, fn value, {sum, previous} ->
      if previous < value do
        {sum + value - 2 * previous, value}
      else
        {sum + value, value}
      end
    end)
    |> elem(0)
  end

  defp roman_value("I"), do: 1
  defp roman_value("V"), do: 5
  defp roman_value("X"), do: 10
  defp roman_value("L"), do: 50
  defp roman_value("C"), do: 100
  defp roman_value("D"), do: 500
  defp roman_value("M"), do: 1000

  defp put_chapters(environment, chapters) do
    Enum.reduce(chapters, {environment, []}, fn {chapter, text}, {environment, refs} ->
      id = "chapter-#{chapter}"

      {:ok, ref, environment} =
        RLM.put_source(environment, text,
          id: id,
          label: "Chapter #{chapter}",
          metadata: %{chapter: chapter, size: String.length(text)}
        )

      {environment, [{chapter, ref} | refs]}
    end)
    |> then(fn {environment, refs} -> {environment, Enum.reverse(refs)} end)
  end

  defp split_chapters(environment, chapter_refs, config) do
    Enum.map(chapter_refs, fn {chapter, ref} ->
      {:ok, slice_set} =
        RLM.split(environment, ref, chunk_size: config.chunk_size, overlap: config.overlap)

      {chapter, ref, slice_set}
    end)
  end

  defp extract_evidence(config, model, environment, chapter_slices, log) do
    tasks =
      Enum.flat_map(chapter_slices, fn {chapter, ref, slice_set} ->
        {:ok, artifacts} = RLM.materialize(environment, slice_set)

        Enum.map(artifacts, fn artifact ->
          %{chapter: chapter, ref: ref, artifact: artifact}
        end)
      end)

    tasks
    |> Task.async_stream(
      fn task ->
        mapper = fn artifact ->
          call =
            call_text!(
              config,
              model,
              evidence_prompt(task.chapter, task.artifact.content),
              output_token_opts(config, config.evidence_tokens),
              %{
                phase: "extract_evidence",
                chapter: task.chapter,
                artifact: task.artifact.id
              },
              log
            )

          LeafResult.new!(
            %{
              chapter: task.chapter,
              artifact_id: task.artifact.id,
              text: call.text
            },
            id: "gatsby:evidence:#{task.chapter}:#{task.artifact.id}",
            artifact: artifact,
            usage: call.usage,
            metadata: %{phase: :extract_evidence, chapter: task.chapter}
          )
        end

        {:ok, [result]} = RLMMapLeaves.map_artifacts([task.artifact], mapper)
        result
      end,
      max_concurrency: config.concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.group_by(& &1.output.chapter)
  end

  defp compose_chapter_analyses(config, model, chapters, evidence, log) do
    Enum.map(chapters, fn {chapter, _text} ->
      chapter_evidence = Map.get(evidence, chapter, [])

      call =
        call_text!(
          config,
          model,
          chapter_analysis_prompt(chapter, chapter_evidence),
          output_token_opts(config, config.chapter_tokens),
          %{phase: "chapter_analysis", chapter: chapter},
          log
        )

      {chapter, call.text}
    end)
  end

  defp compose_overall_analysis(config, model, chapter_analyses, log) do
    call =
      call_text!(
        config,
        model,
        overall_analysis_prompt(chapter_analyses),
        output_token_opts(config, 900),
        %{phase: "overall_analysis"},
        log
      )

    call.text
  end

  defp compose_metaphor_report(config, model, overall_analysis, chapter_analyses, log) do
    call =
      call_text!(
        config,
        model,
        metaphor_report_prompt(overall_analysis, chapter_analyses),
        output_token_opts(config, config.essay_tokens),
        %{phase: "metaphor_report"},
        log
      )

    call.text
  end

  defp compose_executive_summary(config, model, metaphor_report, log) do
    call =
      call_text!(
        config,
        model,
        executive_summary_prompt(metaphor_report),
        output_token_opts(config, config.summary_tokens),
        %{phase: "executive_summary"},
        log
      )

    call.text
  end

  defp translate_outputs(config, model, outputs, log) do
    %{
      spanish_metaphor_report:
        translate(
          config,
          model,
          outputs.metaphor_report,
          "Spanish",
          :spanish_metaphor_report,
          log
        ),
      mandarin_metaphor_report:
        translate(
          config,
          model,
          outputs.metaphor_report,
          "Mandarin Chinese",
          :mandarin_metaphor_report,
          log
        ),
      spanish_executive_summary:
        translate(
          config,
          model,
          outputs.executive_summary,
          "Spanish",
          :spanish_executive_summary,
          log
        ),
      mandarin_executive_summary:
        translate(
          config,
          model,
          outputs.executive_summary,
          "Mandarin Chinese",
          :mandarin_executive_summary,
          log
        )
    }
  end

  defp translate(config, model, text, language, output_name, log) do
    max_tokens =
      if output_name in [:spanish_executive_summary, :mandarin_executive_summary] do
        max(config.summary_tokens * 2, 500)
      else
        config.translation_tokens
      end

    call =
      call_text!(
        config,
        model,
        translator_prompt(text, language),
        output_token_opts(config, max_tokens),
        %{phase: "translate", output: output_name, language: language},
        log
      )

    call.text
  end

  defp call_text!(config, model, prompt, call_opts, label, log) do
    started = monotonic_ms()

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
        Agent.update(log, fn calls ->
          [
            Map.merge(label, %{
              latency_ms: latency_ms,
              usage: call.usage,
              finish_reason: call.finish_reason,
              output_chars: String.length(call.text)
            })
            | calls
          ]
        end)

        Map.put(call, :latency_ms, latency_ms)

      {:error, error} ->
        Agent.update(log, fn calls ->
          [Map.merge(label, %{latency_ms: latency_ms, error: inspect(error)}) | calls]
        end)

        raise "LLM call failed for #{inspect(label)}: #{inspect(error)}"
    end
  end

  defp evidence_prompt(chapter, text) do
    """
    You are a bounded RLM leaf worker analyzing The Great Gatsby.

    Chapter: #{chapter}

    Extract metaphor evidence from this slice. Return concise markdown with:
    - 3 to 6 quoted snippets, each short
    - the metaphor or symbol each quote supports
    - one interpretive sentence about desire, class, memory, performance, or moral decay

    Focus especially on the green light, the eyes of Doctor T. J. Eckleburg, the valley of ashes,
    East Egg and West Egg, cars, shirts, weather, parties, time, and the American Dream when present.
    If none are present, still name any local metaphors that matter.

    Slice text:
    #{text}
    """
  end

  defp chapter_analysis_prompt(chapter, evidence_results) do
    """
    You are composing a per-chapter summary and metaphor analysis for The Great Gatsby.

    Chapter: #{chapter}

    Use only the extracted evidence below. Produce:
    1. A short chapter summary.
    2. A metaphor analysis with quoted citations.
    3. A note on character desire or self-deception.

    Return only the requested analysis. Do not include offers, next steps, or meta commentary.

    Evidence:
    #{leaf_text(evidence_results)}
    """
  end

  defp overall_analysis_prompt(chapter_analyses) do
    """
    You are writing the opening page of a literary essay about metaphors in The Great Gatsby.

    Explain the overall symbolic system of the novel: desire, class performance, money, memory,
    moral decay, spectacle, geography, and the American Dream. Use chapter references where helpful.
    Return only the requested analysis. Do not include offers, next steps, or meta commentary.

    Chapter analyses:
    #{chapter_analyses_text(chapter_analyses)}
    """
  end

  defp metaphor_report_prompt(overall_analysis, chapter_analyses) do
    """
    Write a substantial markdown essay analyzing metaphors in The Great Gatsby, including citations.

    The essay should read like a compact 10-page literary analysis. It must include:
    - an introduction
    - a discussion of the green light
    - a discussion of the valley of ashes and Doctor T. J. Eckleburg
    - geography and class: East Egg, West Egg, New York
    - cars, parties, shirts, weather, and time as metaphoric systems
    - character desire and self-deception
    - a conclusion about the American Dream

    Return only the essay. Do not include offers, next steps, or meta commentary.

    Opening synthesis:
    #{overall_analysis}

    Per-chapter analyses:
    #{chapter_analyses_text(chapter_analyses)}
    """
  end

  defp executive_summary_prompt(metaphor_report) do
    """
    Write a high-level executive summary in 200 words or less of this literary metaphor analysis.
    Preserve the central argument and the most important symbols.
    Return only the summary. Do not include offers, next steps, or meta commentary.

    Report:
    #{metaphor_report}
    """
  end

  defp translator_prompt(text, language) do
    """
    You are an expert literary translator.

    Translate the following text into #{language}. Preserve markdown structure, literary nuance,
    citation markers, and quoted snippets as naturally as possible. Return only the translation.

    #{text}
    """
  end

  defp dry_text(%{phase: "extract_evidence", chapter: chapter}, prompt) do
    "DRY EVIDENCE chapter #{chapter}\n\n" <> String.slice(prompt, 0, 900)
  end

  defp dry_text(%{phase: phase}, prompt) do
    "DRY #{String.upcase(to_string(phase))}\n\n" <> String.slice(prompt, 0, 1_500)
  end

  defp leaf_text(results) do
    results
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn result -> "- #{result.output.artifact_id}: #{result.output.text}" end)
    |> Enum.join("\n")
  end

  defp chapter_analyses_text(chapter_analyses) do
    chapter_analyses
    |> Enum.map(fn {chapter, text} -> "## Chapter #{chapter}\n\n#{text}" end)
    |> Enum.join("\n\n")
  end

  defp evidence_markdown(evidence) do
    evidence
    |> Enum.sort_by(fn {chapter, _results} -> chapter end)
    |> Enum.map(fn {chapter, results} -> "## Chapter #{chapter}\n\n#{leaf_text(results)}" end)
    |> Enum.join("\n\n")
  end

  defp chapter_analyses_markdown(chapter_analyses), do: chapter_analyses_text(chapter_analyses)

  defp write_artifacts!(paths, artifacts) do
    File.mkdir_p!(Path.dirname(paths.metaphor_report))
    File.write!(paths.metaphor_report, artifacts.metaphor_report)
    File.write!(paths.executive_summary, artifacts.executive_summary)
    File.write!(paths.spanish_metaphor_report, artifacts.spanish_metaphor_report)
    File.write!(paths.mandarin_metaphor_report, artifacts.mandarin_metaphor_report)
    File.write!(paths.spanish_executive_summary, artifacts.spanish_executive_summary)
    File.write!(paths.mandarin_executive_summary, artifacts.mandarin_executive_summary)
    File.write!(paths.chapter_analyses, artifacts.chapter_analyses)
    File.write!(paths.evidence, artifacts.evidence)
  end

  defp output_paths(output_path) do
    root = Path.rootname(output_path)

    %{
      metaphor_report: "#{root}_metaphor_report.md",
      executive_summary: "#{root}_executive_summary.md",
      spanish_metaphor_report: "#{root}_metaphor_report_es.md",
      mandarin_metaphor_report: "#{root}_metaphor_report_zh.md",
      spanish_executive_summary: "#{root}_executive_summary_es.md",
      mandarin_executive_summary: "#{root}_executive_summary_zh.md",
      chapter_analyses: "#{root}_chapter_analyses.md",
      evidence: "#{root}_evidence.md"
    }
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
      details: Enum.map(calls, &call_detail/1),
      estimated_cost_usd: estimate_cost(config.model, input_tokens, output_tokens)
    }
  end

  defp call_detail(call) do
    call
    |> Map.take([
      :phase,
      :chapter,
      :artifact,
      :output,
      :language,
      :finish_reason,
      :latency_ms,
      :output_chars,
      :usage
    ])
    |> stringify_finish_reason()
  end

  defp stringify_finish_reason(call) do
    case Map.fetch(call, :finish_reason) do
      {:ok, reason} -> Map.put(call, :finish_reason, to_string(reason))
      :error -> call
    end
  end

  defp artifact_metrics(artifacts) do
    Map.new(artifacts, fn {name, text} ->
      {name,
       %{
         chars: String.length(text),
         words: word_count(text),
         assistant_offer?: assistant_offer?(text)
       }}
    end)
  end

  defp word_count(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> length()
  end

  defp assistant_offer?(text) do
    text
    |> String.downcase()
    |> then(&(String.contains?(&1, "if you want") or String.contains?(&1, "i can also")))
  end

  defp merge_usage(call, acc) do
    call
    |> Map.get(:usage, %{})
    |> Enum.reduce(acc, fn {key, value}, acc ->
      if is_number(value), do: Map.update(acc, key, value, &(&1 + value)), else: acc
    end)
  end

  defp usage_value(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
    end)
  end

  defp score_report(report) do
    normalized = normalize_text(report)

    marker_results =
      Enum.map(@report_markers, fn {marker, alternatives} ->
        hit? = Enum.any?(alternatives, &String.contains?(normalized, normalize_text(&1)))
        {marker, hit?}
      end)

    hits = marker_results |> Enum.filter(fn {_marker, hit?} -> hit? end) |> Enum.map(&elem(&1, 0))

    missing =
      marker_results |> Enum.reject(fn {_marker, hit?} -> hit? end) |> Enum.map(&elem(&1, 0))

    %{
      hit_count: length(hits),
      total: map_size(@report_markers),
      ratio: Float.round(length(hits) / map_size(@report_markers), 3),
      hits: hits,
      missing: missing
    }
  end

  defp estimated_total_calls(chapters, chapter_slices) do
    slice_count(chapter_slices) + length(chapters) + 1 + 1 + 1 + 4
  end

  defp slice_count(chapter_slices) do
    Enum.reduce(chapter_slices, 0, fn {_chapter, _ref, slice_set}, count ->
      count + length(slice_set.slices)
    end)
  end

  defp output_token_opts(%{model: "openai:" <> model_id}, tokens) do
    if openai_reasoning_model?(model_id),
      do: [max_completion_tokens: tokens],
      else: [max_tokens: tokens]
  end

  defp output_token_opts(_config, tokens), do: [max_tokens: tokens]

  defp output_token_limit(opts),
    do: Keyword.get(opts, :max_tokens) || Keyword.get(opts, :max_completion_tokens)

  defp openai_reasoning_model?(model_id) do
    String.starts_with?(model_id, "gpt-5") or String.starts_with?(model_id, "gpt-4.1") or
      String.starts_with?(model_id, "o1") or String.starts_with?(model_id, "o3") or
      String.starts_with?(model_id, "o4")
  end

  defp model_for("openai:" <> model_id) do
    ReqLLM.model!(%{provider: :openai, id: model_id, provider_model_id: model_id})
  end

  defp model_for(model), do: model

  defp estimate_cost("openai:gpt-5.4-mini", input_tokens, output_tokens)
       when is_number(input_tokens) and is_number(output_tokens) do
    Float.round(
      input_tokens / 1_000_000 * @gpt_54_mini_input_per_mtok +
        output_tokens / 1_000_000 * @gpt_54_mini_output_per_mtok,
      6
    )
  end

  defp estimate_cost(_model, _input_tokens, _output_tokens), do: nil

  defp estimate_dry_usage(prompt, max_tokens) do
    input_tokens = div(String.length(prompt) + 3, 4)
    output_tokens = min(max_tokens || 500, 300)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  defp print_summary(result) do
    IO.puts("\nRLM Gatsby smoke complete")
    IO.puts("  output: #{result.output_paths.metaphor_report}")
    IO.puts("  json: #{result.json_output_path}")
    IO.puts("  dry_run: #{result.dry_run}")
    IO.puts("  chapters: #{result.task.chapter_count}; slices: #{result.task.slice_count}")
    IO.puts("  score: #{result.score.hit_count}/#{result.score.total}")
    IO.puts("  calls: #{result.calls.count}; exact estimate: #{result.rlm_plan.exact_match}")

    IO.puts(
      "  elapsed_ms: #{result.elapsed_ms}; estimated_cost_usd: #{inspect(result.calls.estimated_cost_usd)}"
    )
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, count) when is_integer(count) and count > 0, do: Enum.take(list, count)

  defp normalize_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9"]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truthy?(value) when value in ["1", "true", "TRUE", "yes", "YES"], do: true
  defp truthy?(_), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp drop_leading_separator(["--" | rest]), do: rest
  defp drop_leading_separator(argv), do: argv

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

RunicAI.Manual.RLMGatsbySmoke.main(System.argv())
