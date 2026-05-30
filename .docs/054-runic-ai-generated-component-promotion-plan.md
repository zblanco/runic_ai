# RunicAI Generated Component Promotion Plan

Status: proposed

Date: 2026-05-30

## Purpose

RunicAI already has dynamic workflow generation, sandbox execution, model-visible
sandbox tools, and Runic-native compilation paths. The next useful step is to
connect those pieces into a disciplined promotion loop for generated Runic
components.

The target is:

```text
component gap
  -> generated leaf proposal
  -> sandbox-only implementation
  -> streamed proof run
  -> review and policy gate
  -> reusable catalog component
```

This is the RunicAI-side complement to
`.docs/053-runic-sandbox-consumer-driven-improvement-plan.md`. The sandbox plan
defines the substrate improvements. This plan defines the product and runtime
loop that should consume them.

## Design Principle

Generated code is never trusted because it compiled. It becomes eligible for
reuse only after it has:

- an explicit input/output contract;
- an allowed runtime and sandbox profile;
- generated source or artifact provenance;
- sandbox proof evidence;
- bounded stdout/stderr and trace events;
- deterministic tests or examples;
- a promotion decision that can be reviewed and replayed.

The coordinator may generate drafts. The sandbox proves behavior. RunicAI
promotes only the resulting component contract and audited artifact.

## Current Baseline

Useful existing pieces:

- dynamic assistant/RLM blueprints compile into Runic-owned workflow graphs;
- component catalog entries exist for assistant/RLM workflows;
- sandbox execution is exposed through `execute_code`, `sandbox_status`, and
  sandbox component/tool surfaces;
- capability profiles can carry backend, runtime, network, workspace, metadata,
  and policy configuration;
- coding/workbench surfaces already preserve terminal and trace events;
- `runic_sandbox` now has attach-shaped streaming and session events.

Missing pieces:

- no first-class generated-component lifecycle;
- no proof artifact tying generated source, sandbox run, tests, and promotion
  decision together;
- no shared bridge from `RunicSandbox.SessionEvent` into RunicAI trace/terminal
  events;
- no catalog state that distinguishes draft, proven, reviewed, and reusable
  generated components;
- no policy that prevents generated code from bypassing sandbox proof.

## Component Lifecycle

Generated components should move through explicit states:

```text
draft
  -> sandbox_proving
  -> sandbox_proven
  -> review_requested
  -> review_approved
  -> catalog_available
```

Failure states:

```text
draft_rejected
sandbox_failed
contract_failed
review_rejected
promotion_revoked
```

Each state transition should be evented and durable enough for a user or agent
to answer:

- what was generated;
- why it was generated;
- what sandbox ran it;
- what input/output contract it claimed;
- what proof command ran;
- what stdout/stderr was observed;
- what artifacts were produced;
- who or what approved promotion.

## Data Shape

Start with a data model that can live in memory or existing trace artifacts,
then persist it once the workflow proves useful.

```elixir
%RunicAI.GeneratedComponent.Proposal{
  id: "component_...",
  source: :agent_generated,
  reason: "No built-in parser handles this fixture shape",
  runtime: :elixir,
  module_name: "RunicAI.Generated.Components.InvoiceParser",
  contract: %{
    input_schema: %{...},
    output_schema: %{...},
    examples: [...]
  },
  files: [
    %{path: "lib/generated/invoice_parser.ex", content_ref: "..."}
  ],
  sandbox_profile: %{
    backend: :docker,
    runtime: :elixir,
    network: :disabled
  },
  proof: nil,
  status: :draft,
  metadata: %{}
}
```

Proof result:

```elixir
%RunicAI.GeneratedComponent.Proof{
  id: "proof_...",
  proposal_id: "component_...",
  sandbox_session_id: "...",
  attach_id: "...",
  backend: :docker,
  attach_mode: :terminal_adapter,
  command: ["mix", "test", "test/generated/invoice_parser_test.exs"],
  exit_status: 0,
  stdout_bytes: 12_304,
  stderr_bytes: 0,
  events_ref: "...",
  artifacts: [...],
  contract_result: :pass,
  status: :pass,
  metadata: %{}
}
```

## Runtime Flow

### 1. Detect Capability Gap

The coordinator should prefer existing components. A generated component is
allowed only when the planner can explain the gap:

- no existing component matches the required contract;
- adapting an existing component would be more complex than a new leaf;
- the new leaf is narrow and testable;
- the runtime and sandbox profile are allowed by policy.

Output: `GeneratedComponent.Proposal` in `:draft`.

### 2. Generate Contract Before Code

The model proposes:

- component name and purpose;
- input schema;
- output schema;
- examples;
- deterministic test cases;
- allowed runtime;
- allowed dependencies, defaulting to none;
- sandbox profile.

RunicAI validates the contract before any source is accepted.

Output: validated draft proposal.

### 3. Materialize Only In Sandbox

The proof runner writes generated files into the sandbox workspace, not into the
host project tree. Inline code is acceptable for early proofs, but repeated or
promotable components should materialize as files inside the sandbox workspace
so compile/test/artifact evidence is realistic.

Output: sandbox session with generated source.

### 4. Run Proof Through `runic_sandbox`

The proof runner opens a session and runs the proof command through
`RunicSandbox.attach/3` when available. Early phases may accept terminal attach
adapters. Interactive REPL proof requires live streaming and stdin support.

Default policy:

- `network: :disabled`;
- `persist_changes?: false`;
- explicit timeout;
- explicit max output bytes;
- runtime allow-list from the proposal;
- no host bind mounts unless the user or profile explicitly permits them.

Output: `GeneratedComponent.Proof`.

### 5. Bridge Events Into RunicAI

RunicAI should add one bridge that converts sandbox events into its existing
event surfaces:

- terminal events for operator visibility;
- trace events for replay/debugging;
- proof-log events for promotion decisions;
- summarized observations for model feedback.

The bridge should preserve:

- backend;
- session id;
- attach id;
- attach mode;
- runtime;
- command;
- stream type;
- byte counts;
- terminal status.

Output: durable or trace-referenced proof event log.

### 6. Contract Check And Review

After the sandbox command succeeds, RunicAI validates:

- output schema matches examples;
- tests passed;
- no forbidden runtime/network behavior occurred;
- output stayed within policy;
- artifacts are declared;
- no host write path was used.

The component then moves to `:sandbox_proven` and can request review. Review can
be user approval, policy approval for low-risk generated leaves, or a second
model/reviewer lane, depending on the capability profile.

Output: `:review_approved` or a rejection state.

### 7. Promote To Catalog

Promotion should make the component available by reference, not by blindly
loading arbitrary generated modules into the host VM.

Early promotion options:

- catalog entry that reruns the sandboxed implementation by reference;
- catalog entry that points at a reviewed generated artifact;
- catalog entry that uses a host implementation only after explicit user
  approval and code movement.

Default should be sandbox-backed reuse. Host-native promotion is a later,
higher-trust action.

Output: `:catalog_available`.

## Implementation Phases

### Phase 1: Proof Runner Skeleton

- add generated-component proposal and proof structs;
- implement fake-backend and terminal-adapter proof tests;
- run proof commands through `RunicSandbox.attach/3` when supported;
- fall back to `RunicSandbox.exec/2` only when the profile explicitly allows a
  non-streaming proof;
- emit proof summary as a trace artifact.

Exit criteria:

- a generated inline Elixir or Bash leaf can be proven in a sandbox without
  writing to the host tree;
- failed proof captures stdout/stderr and terminal status.

### Phase 2: Event Bridge

- add `RunicAI.Sandbox.EventBridge`;
- normalize `:stdout_chunk`, `:stderr_chunk`, `:exec_started`, and
  `:exec_finished`;
- synthesize failure when a stream ends without terminal status;
- let backend failure override prior success;
- produce terminal and trace events from the same bridge.

Exit criteria:

- generated-component proof logs and workbench terminal output use the same
  sandbox bridge;
- tests cover duplicate terminal and success-then-failure cases.

### Phase 3: Contract-First Component Drafts

- add component draft validation;
- require input/output schemas before source proof;
- generate deterministic examples/tests from the contract;
- reject drafts that request disallowed runtime, network, or host filesystem
  permissions.

Exit criteria:

- a coordinator can propose a generated leaf as data;
- invalid contracts fail before sandbox execution.

### Phase 4: Promotion Ratchet

- persist or trace-link proposal, proof, contract, artifacts, and approval;
- expose promotion state in the workbench or CLI;
- make catalog lookup distinguish built-in, sandbox-backed generated, and
  host-native reviewed components;
- default generated components to sandbox-backed execution.

Exit criteria:

- a proven component can be reused by a later generated workflow without
  rerunning the generation step;
- provenance remains inspectable.

### Phase 5: Interactive And MCP-Aware Proofs

- require `attach_mode: :live_stream` for REPL-style generated components;
- require stdin support for interactive proof loops;
- require `network: :restricted` with explicit allow-list metadata for any MCP
  or model endpoint;
- reuse the substrate improvements from the Runic Sandbox consumer-driven plan.

Exit criteria:

- a generated component can call a scoped service/MCP endpoint from inside the
  sandbox while unrelated egress remains denied;
- the same readiness checks are compatible with Ariston's CLI containment path.

## Policy Defaults

Default generated-component proof policy:

```elixir
%{
  backend: :docker,
  runtime: :elixir,
  network: :disabled,
  timeout_ms: 30_000,
  max_output_bytes: 65_536,
  persist_changes?: false,
  attach_mode: :terminal_adapter,
  host_writes?: false,
  review_required?: true
}
```

Escalations must be explicit:

- network access requires `:restricted` plus allow-list metadata;
- live stdin requires live attach support;
- host-native promotion requires user approval;
- dependency installation requires a declared dependency policy;
- long-running service proof requires service/proxy capability metadata.

## Ariston Alignment

Ariston's early adopter path is stricter because it wants to contain a
long-lived provider CLI. RunicAI can still help by validating the shared lower
layers first:

- attach event semantics;
- readiness checks;
- terminal reconciliation;
- restricted-network metadata;
- MCP boundary metadata;
- Docker smoke profiles;
- generated proof artifacts.

This lets RunicAI dog-food the component promotion loop immediately while
keeping pressure on the exact `runic_sandbox` features Ariston needs.

## Open Decisions

- Should generated component proposals be stored in the existing run artifact
  model first, or should they get a dedicated table immediately?
- Should sandbox-backed generated catalog entries execute through a generic
  adapter component, or should each generated leaf have a stable component spec
  that points to its proof artifact?
- What is the minimum contract schema shape for phase 1: JSON schema, Nimble
  options-style data, or existing RLM component blueprint schemas?
- Should low-risk generated components ever auto-promote from
  `:sandbox_proven`, or should review always be required at first?
- How much of the Ariston bridge semantics should move into `runic_sandbox`
  versus RunicAI's consumer bridge?

## Non-Goals

- Do not execute generated component source on the host during proof.
- Do not make full agent CLI containment a prerequisite for phase 1.
- Do not add generated modules to the host code path without explicit
  promotion and review.
- Do not let the planner skip existing catalog components without explaining
  the capability gap.
- Do not duplicate backend implementation details outside `packages/runic_sandbox`.
