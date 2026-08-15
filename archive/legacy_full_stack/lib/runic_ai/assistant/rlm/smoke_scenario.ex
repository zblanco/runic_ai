defmodule RunicAI.Assistant.RLM.SmokeScenario do
  @moduledoc """
  Scenario data for assistant RLM smoke and progression runs.
  """

  @enforce_keys [
    :id,
    :objective,
    :inputs,
    :output,
    :required_sections,
    :expected_workflow_capabilities,
    :source_cues,
    :manual_review_checklist
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :objective,
    :inputs,
    :output,
    :required_sections,
    :expected_workflow_capabilities,
    :manual_review_checklist,
    source_cues: []
  ]

  @type t :: %__MODULE__{
          id: atom(),
          objective: String.t(),
          inputs: [Path.t()],
          output: Path.t(),
          required_sections: [String.t()],
          expected_workflow_capabilities: [atom()],
          source_cues: [String.t()],
          manual_review_checklist: [String.t()]
        }

  @spec all() :: [t()]
  def all do
    [
      scenario(
        :long_document_wiki,
        "Read tmp/wandering-inn-10-59-t.md and write a wiki-style chapter page with overview, events, notable characters, plot points, reveals, takeaways, and provenance.",
        ["tmp/wandering-inn-10-59-t.md"],
        "tmp/assistant_smoke/artifacts/wandering-inn-10-59-t-summary.md",
        ["Overview", "Events", "Characters", "Plot", "Reveals", "Takeaways"],
        [:source_splitting, :llm_map, :hierarchical_reduce, :artifact_write]
      ),
      scenario(
        :meeting_actions,
        "Turn tmp/assistant_meeting_transcript.md into decisions, action items, owners, deadlines, open questions, and risks.",
        ["tmp/assistant_meeting_transcript.md"],
        "tmp/assistant_smoke/artifacts/assistant-meeting-actions.md",
        ["Decisions", "Action Items", "Owners", "Deadlines", "Open Questions", "Risks"],
        [:source_splitting, :llm_map, :record_group, :report_composer],
        ["docs-only", "trace summary", "Friday", "dynamic proposals"]
      ),
      scenario(
        :research_brief,
        "Create a research brief from tmp/assistant_research_brief.md with problem statement, method, claims, evidence, limitations, glossary, and implementation implications.",
        ["tmp/assistant_research_brief.md"],
        "tmp/assistant_smoke/artifacts/assistant-research-brief.md",
        ["Problem", "Method", "Claims", "Evidence", "Limitations", "Glossary", "Implementation"],
        [:source_splitting, :llm_map, :record_group, :report_composer],
        ["ReAct", "lambda-RLM", "Tier 0", "scorecard"]
      ),
      scenario(
        :ticket_clusters,
        "Cluster tmp/assistant_tickets.jsonl into themes, customer impact, repeated failure modes, and ranked priorities.",
        ["tmp/assistant_tickets.jsonl"],
        "tmp/assistant_smoke/artifacts/assistant-ticket-themes.md",
        ["Themes", "Customer Impact", "Failure Modes", "Priority", "Examples"],
        [:tabular_parser, :record_map, :record_group, :report_composer],
        ["SSO callback", "Invoice CSV", "stale session"]
      ),
      scenario(
        :notes_digest,
        "Write a weekly digest from tmp/assistant_notes with recurring themes, commitments, unresolved threads, and suggested follow-ups.",
        ["tmp/assistant_notes"],
        "tmp/assistant_smoke/artifacts/assistant-weekly-digest.md",
        ["Themes", "Commitments", "Unresolved", "Follow-ups"],
        [:source_discovery, :source_splitting, :llm_map, :record_group],
        ["trace summaries", "Budget ledgers", "fallback thresholds"]
      ),
      scenario(
        :architecture_report,
        "Build a high-level architecture report for RunicAI focusing on runtime, RLM, terminal harness, and coding-agent boundaries.",
        ["."],
        "tmp/assistant_smoke/artifacts/assistant-runic-ai-architecture-report.md",
        ["Runtime", "RLM", "Terminal", "Coding Agent", "Boundaries"],
        [:source_discovery, :source_splitting, :llm_map, :objective_scorecard],
        ["RunicAI", "ReqLLM", "Terminal", "Coding"]
      ),
      scenario(
        :csv_cleanup,
        "Infer cleanup rules for tmp/assistant_messy_contacts.csv, produce a cleaned preview, explain uncertain rows, and write a cleanup plan.",
        ["tmp/assistant_messy_contacts.csv"],
        "tmp/assistant_smoke/artifacts/assistant-contacts-cleanup-plan.md",
        ["Cleanup Rules", "Preview", "Uncertain Rows", "Plan"],
        [:tabular_parser, :record_map, :record_group, :report_composer],
        ["ADA@example.COM", "bea@invalid", "duplicate"]
      ),
      scenario(
        :document_comparison,
        "Compare tmp/assistant_policy_old.md and tmp/assistant_policy_new.md, identify material changes, affected stakeholders, and open questions.",
        ["tmp/assistant_policy_old.md", "tmp/assistant_policy_new.md"],
        "tmp/assistant_smoke/artifacts/assistant-policy-migration-brief.md",
        ["Material Changes", "Stakeholders", "Open Questions", "Migration"],
        [:source_discovery, :document_compare, :record_group, :report_composer],
        ["one business day", "immediately", "Enterprise customers"]
      )
    ]
  end

  @spec get(atom() | String.t()) :: {:ok, t()} | :error
  def get(id) do
    normalized = normalize_id(id)

    all()
    |> Enum.find(&(&1.id == normalized))
    |> case do
      nil -> :error
      scenario -> {:ok, scenario}
    end
  end

  @spec ensure_fixtures!(Path.t()) :: :ok
  def ensure_fixtures!(root) when is_binary(root) do
    fixtures()
    |> Enum.each(fn {path, content} ->
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))

      unless File.exists?(absolute) do
        File.write!(absolute, content)
      end
    end)

    :ok
  end

  defp scenario(id, objective, inputs, output, required_sections, capabilities, source_cues \\ []) do
    %__MODULE__{
      id: id,
      objective: objective,
      inputs: inputs,
      output: output,
      required_sections: required_sections,
      expected_workflow_capabilities: capabilities,
      source_cues: source_cues,
      manual_review_checklist: [
        "artifact exists",
        "required sections are present",
        "source-specific cues are preserved",
        "source/provenance coverage is visible when requested",
        "residual risks are explicit",
        "workflow shape matches expected capabilities"
      ]
    }
  end

  defp normalize_id(id) when is_atom(id), do: id

  defp normalize_id(id) when is_binary(id) do
    normalized = String.replace(id, "-", "_")

    all()
    |> Enum.map(& &1.id)
    |> Enum.find(&(Atom.to_string(&1) == normalized))
  end

  defp fixtures do
    %{
      "tmp/wandering-inn-10-59-t.md" => """
      # Chapter 10.59 T Smoke Fixture

      This synthetic fallback fixture exists only when the real cached chapter
      fixture is absent. It gives the long-document smoke a stable local source
      without requiring a network fetch.

      ## Opening

      Talia reaches the old archive at dawn and finds that the door has already
      been opened. She records the broken seal, the missing survey ledger, and
      the ash on the threshold.

      ## Middle

      The archivist Rowan admits that three visitors entered during the storm:
      a courier carrying a blue case, a retired captain asking about river maps,
      and a child looking for a family name. Talia notices the same copper dust
      on the map cabinet and on the courier's glove.

      ## Turn

      Rowan reveals that the missing ledger describes a road under the river.
      The captain wanted the road sealed, while the courier wanted proof that
      the road still existed. The child recognizes the old road name as a family
      oath rather than a place.

      ## Close

      Talia keeps the blue case unopened, sends Rowan to warn the bridge watch,
      and marks the family oath as the central clue for the next investigation.
      """,
      "tmp/assistant_meeting_transcript.md" => """
      # Product Sync

      09:00 Ada: Decision: keep the docs-only write policy for assistant smoke reports.
      09:04 Bea: Action: add a trace summary helper by Friday.
      09:07 Cam: Risk: scenario outputs may look plausible without source coverage.
      09:10 Ada: Open question: when should dynamic proposals fall back to recipes?
      """,
      "tmp/assistant_research_brief.md" => """
      # Cached RLM Research Source Brief

      This markdown fixture is derived from project-owned notes in `.docs` and
      the research references cited by `livebooks/rlm-summarizer.livemd`.

      ## References

      - ReAct: `https://arxiv.org/abs/2210.03629`
      - Recursive Language Models: `https://arxiv.org/abs/2512.24601`
      - lambda-RLM: `https://arxiv.org/abs/2603.20105`
      - lambda-RLM implementation: `https://github.com/lambda-calculus-LLM/lambda-RLM`
      - Slate agent-systems report: `https://randomlabs.ai/blog/slate`

      ## Problem

      One-shot workflow generation can fail validation, choose weak evidence
      paths, or produce plausible final prose without proving that its workflow
      actually covered the requested sources. RunicAI needs a way to test
      whether an assistant can generate the workflow as data, validate it,
      repair it, and fall back to known shapes when generation fails.

      ## Method

      Compare three runs over the same task: a generic fallback workflow, a
      model-proposed workflow blueprint, and a repaired blueprint after
      validation or scorecard failure. The workflow should use ordinary Runic
      components such as source discovery, splitting, map/reduce model leaves,
      record grouping, report composition, artifact writing, and objective
      scorecards.

      ## Claims

      ReAct is useful as a local thought/action loop, but it does not by itself
      provide a durable typed workflow contract. Recursive Language Models and
      lambda-RLM point toward explicit scaffolds around model calls. RunicAI can
      adapt that lesson by making the workflow graph deterministic data and
      keeping stochastic calls at typed leaves. Tier 0 and Tier 1 function
      blueprints cover common grouping, selection, normalization, and templating
      work without opening arbitrary Elixir execution.

      ## Evidence

      The local `.docs/020` and `.docs/010` notes both emphasize typed control
      structures around LLM leaves. The `.docs/031` plan narrows the next
      implementation step to dynamic assistant workflow proposal, validation,
      repair, and smoke evidence. The smoke matrix adds measurable expectations:
      artifact existence, section coverage, source coverage, component shape,
      and repair behavior.

      ## Limitations

      LLM judging remains noisy and should be paired with deterministic checks.
      Component coverage is also not the same as output quality: a workflow can
      use the expected nodes and still produce a weak report. Conversely, a
      generic fallback can sometimes produce a useful artifact while missing the
      component shape a scenario was designed to pressure.

      ## Glossary

      - Workflow blueprint: a JSON-like data structure describing components,
        edges, policies, and stop conditions.
      - Tier 0 function: a fixed built-in operation such as identity, get, pick,
        or template.
      - Tier 1 function: a bounded expression blueprint evaluated by the runtime.
      - Tier 2 function: arbitrary Elixir source, review-gated and disabled by
        default.
      - Scorecard: deterministic verification of artifact, section, source,
        provenance, and budget evidence.

      ## Implementation Implications

      Keep the assistant coordinator dynamic, but make the substrate shared.
      `RunicAI.RLM.Components` should own source discovery, tabular parsing,
      record transforms, grouping, comparison, report composition, scorecards,
      and budgets so assistant and coding agents can reuse the same pieces.
      """,
      "tmp/assistant_tickets.jsonl" => """
      {"ticket_id":"T1","theme":"login","severity":"high","summary":"SSO callback loops after timeout","impact":"admins blocked"}
      {"ticket_id":"T2","theme":"billing","severity":"medium","summary":"Invoice CSV has duplicate rows","impact":"finance cleanup"}
      {"ticket_id":"T3","theme":"login","severity":"high","summary":"SSO retry creates stale session","impact":"admins blocked"}
      """,
      "tmp/assistant_notes/monday.md" => """
      # Monday
      Ada committed to finish trace summaries. The team revisited dynamic fallback thresholds.
      """,
      "tmp/assistant_notes/wednesday.md" => """
      # Wednesday
      Budget ledgers came up again. Open thread: compare generated plans against known recipes.
      """,
      "tmp/assistant_messy_contacts.csv" => """
      name,email,company,status
      Ada Lovelace, ADA@example.COM,RunicAI,active
      ada lovelace,ada@example.com,Runic AI,duplicate
      Bea Stone,bea@invalid,ExampleCo,needs-review
      """,
      "tmp/assistant_policy_old.md" => """
      # Support Policy
      Response target is two business days.
      Security incidents are escalated weekly.
      """,
      "tmp/assistant_policy_new.md" => """
      # Support Policy
      Response target is one business day.
      Security incidents are escalated immediately.
      Enterprise customers receive a migration contact.
      """
    }
  end
end
