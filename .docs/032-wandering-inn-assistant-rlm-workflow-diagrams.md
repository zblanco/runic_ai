# Wandering Inn Assistant RLM Workflow Diagrams

Status: observed run diagrams

Date: 2026-04-30

Source trace:

- `tmp/wandering-inn-10-59-t.assistant-rlm.jsonl`

Run artifact:

- `.docs/wandering-inn-10-59-t-summary.md`

## Observed Run Summary

- Session: `assistant:cli:3394`
- Blueprint: `assistant:generic_report`
- Input: `tmp/wandering-inn-10-59-t.md`
- Output: `.docs/wandering-inn-10-59-t-summary.md`
- Default model capability: `openai:gpt-5.4-mini`
- Source split: 43 paragraph slices
- Materialized slice set: 20 slices, truncated by materialization budget
- LLM map: 20 per-slice note outputs
- LLM reduce/synthesis: 20 mapped items reduced into final report text
- Artifact write: 15,240 bytes
- Verification: `objective_satisfied`, artifact present, no residual risks
- Runtime window: approximately 5 minutes 25 seconds from terminal start to completion

## Control Workflow

```mermaid
flowchart TD
  CLI["Terminal command<br/>mix runic_ai.agent --agent assistant"]
  Runner["RunicAI.Terminal.AssistantRunner<br/>session assistant:cli:3394"]
  Agent["RunicAI.Assistant.RLM.Agent"]
  Manifest["Capability manifest<br/>8 component types<br/>Tier 0 and Tier 1 functions<br/>docs_only writes"]
  Coordinator["Coordinator fallback proposal<br/>assistant:generic_report"]
  Validator["BlueprintValidator<br/>accepted<br/>diagnostics: none"]
  Compiler["WorkflowCompiler<br/>compiled graph summary<br/>6 nodes"]
  Execute["Execute generated workflow"]
  Scorecard["Scorecard<br/>objective_satisfied<br/>artifact present<br/>risks: none"]
  JSONL["JSONL trace sink<br/>30 normalized events"]
  Final["Final terminal report<br/>status: ok"]

  CLI --> Runner
  Runner --> Agent
  Agent --> Manifest
  Manifest --> Coordinator
  Coordinator --> Validator
  Validator --> Compiler
  Compiler --> Execute
  Execute --> Scorecard
  Scorecard --> Final

  Runner -. "writes every normalized event" .-> JSONL
  Agent -. "stage events" .-> JSONL
  Execute -. "node started/completed events" .-> JSONL
  Scorecard -. "summary event" .-> JSONL
```

## Generated Blueprint Graph

```mermaid
flowchart LR
  Source["source_1<br/>tmp/wandering-inn-10-59-t.md"]

  Split["split_sources<br/>source_splitter<br/>strategy: paragraph<br/>max_bytes: 8000<br/>output: 43 slices"]

  Materialize["materialize_slices<br/>source_materializer<br/>max_slice_bytes: 8000<br/>max_total_bytes: 160000<br/>output: 20 slices<br/>truncated: true"]

  Map["extract_slice_notes<br/>llm_map<br/>limit: 80<br/>output: 20 notes<br/>truncated: false"]

  Synthesize["synthesize_report<br/>llm_leaf<br/>strategy: llm_reduce<br/>max_group_items: 12<br/>input count: 20"]

  Write["write_artifact<br/>artifact_writer<br/>path: .docs/wandering-inn-10-59-t-summary.md<br/>write_policy: docs_only<br/>bytes: 15240"]

  Verify["verify_objective<br/>verification<br/>artifact_status: present<br/>objective_status: objective_satisfied<br/>residual_risks: none"]

  Source --> Split
  Split --> Materialize
  Materialize --> Map
  Map --> Synthesize
  Synthesize --> Write
  Write --> Verify
```

## Long-Document Map And Reduce Workflow

The trace reports 20 mapped items entering `synthesize_report`. Because the
generated reducer uses `max_group_items: 12`, the group reduction shape below is
the effective shape implied by the component settings: two group synthesis calls
followed by one final synthesis call.

```mermaid
flowchart TD
  Chapter["Long chapter markdown file"]
  Paragraphs["Paragraph splitter<br/>43 slices"]
  Budget["Materialization budget<br/>20 slices retained<br/>truncated: true"]

  subgraph MapPhase["LLM map phase"]
    M1["slice 1 prompt"]
    M2["slice 2 prompt"]
    MMore["..."]
    M20["slice 20 prompt"]
  end

  Notes["20 slice-note outputs"]

  subgraph ReducePhase["Hierarchical LLM reduce phase"]
    G1["group reduce<br/>items 1-12"]
    G2["group reduce<br/>items 13-20"]
    FinalSynthesis["final synthesis<br/>wiki-style report"]
  end

  Artifact["Markdown artifact<br/>.docs/wandering-inn-10-59-t-summary.md<br/>15,240 bytes"]

  Chapter --> Paragraphs
  Paragraphs --> Budget
  Budget --> M1
  Budget --> M2
  Budget --> MMore
  Budget --> M20
  M1 --> Notes
  M2 --> Notes
  MMore --> Notes
  M20 --> Notes
  Notes --> G1
  Notes --> G2
  G1 --> FinalSynthesis
  G2 --> FinalSynthesis
  FinalSynthesis --> Artifact
```

## Runtime Sequence

```mermaid
sequenceDiagram
  autonumber
  participant User
  participant CLI as Terminal CLI
  participant Runner as AssistantRunner
  participant Agent as Assistant RLM Agent
  participant Coord as Coordinator
  participant Val as BlueprintValidator
  participant WF as WorkflowCompiler
  participant LLM as LLM Provider
  participant FS as Workspace Files

  User->>CLI: run assistant command
  CLI->>Runner: parse options and open JSONL sink
  Runner->>Agent: run objective with input and output paths
  Agent->>Coord: request workflow blueprint
  Coord-->>Agent: generic split/map/reduce/write/verify blueprint
  Agent->>Val: validate blueprint
  Val-->>Agent: accepted, diagnostics empty
  Agent->>WF: compile and execute blueprint
  WF->>FS: read tmp/wandering-inn-10-59-t.md
  WF-->>Agent: split_sources completed, 43 slices
  WF-->>Agent: materialize_slices completed, 20 retained
  WF->>LLM: 20 slice-note map calls
  LLM-->>WF: 20 mapped notes
  WF->>LLM: grouped reduction over 20 notes
  LLM-->>WF: synthesized wiki-style report
  WF->>FS: write .docs/wandering-inn-10-59-t-summary.md
  FS-->>WF: artifact written, 15,240 bytes
  WF->>FS: verify artifact exists
  WF-->>Agent: scorecard objective_satisfied
  Agent-->>Runner: completed result
  Runner-->>CLI: final report status ok
```

## Execution Timing View

```mermaid
gantt
  title Assistant RLM Run Timing From JSONL Trace
  dateFormat HH:mm:ss
  axisFormat %H:%M:%S

  section Setup
  Terminal start and capability manifest :done, setup, 17:12:06, 1s
  Blueprint proposal and validation      :done, plan, 17:12:06, 1s

  section Workflow Nodes
  split_sources                          :done, split, 17:12:06, 1s
  materialize_slices                     :done, materialize, 17:12:06, 1s
  extract_slice_notes                    :done, map, 17:12:06, 17:16:09
  synthesize_report                      :done, reduce, 17:16:09, 17:17:31
  write_artifact                         :done, write, 17:17:31, 1s
  verify_objective                       :done, verify, 17:17:31, 1s

  section Completion
  execution_completed and scorecard      :done, complete, 17:17:31, 1s
```

## State Machine View

```mermaid
stateDiagram-v2
  [*] --> SessionStarted
  SessionStarted --> CapabilitiesPrepared
  CapabilitiesPrepared --> BlueprintProposed
  BlueprintProposed --> ValidationAccepted
  ValidationAccepted --> RunningNode_split_sources
  RunningNode_split_sources --> RunningNode_materialize_slices: 43 slices
  RunningNode_materialize_slices --> RunningNode_extract_slice_notes: 20 materialized slices
  RunningNode_extract_slice_notes --> RunningNode_synthesize_report: 20 mapped notes
  RunningNode_synthesize_report --> RunningNode_write_artifact: synthesized report
  RunningNode_write_artifact --> RunningNode_verify_objective: artifact written
  RunningNode_verify_objective --> ExecutionCompleted: objective_satisfied
  ExecutionCompleted --> ScorecardCompleted
  ScorecardCompleted --> Completed
  Completed --> [*]
```

## Artifact And Evidence Flow

```mermaid
flowchart TD
  Trace["JSONL trace<br/>30 events"]
  Proposal["Generated proposal<br/>assistant:generic_report<br/>6 nodes"]
  Episodes["Episode evidence<br/>6 satisfied node episodes"]
  Artifact["Markdown artifact<br/>.docs/wandering-inn-10-59-t-summary.md"]
  Scorecard["Scorecard<br/>artifact present<br/>objective_satisfied<br/>source_count: 1<br/>residual_risks: none"]

  Trace --> Proposal
  Trace --> Episodes
  Episodes --> Artifact
  Artifact --> Scorecard
  Scorecard --> Trace
```
