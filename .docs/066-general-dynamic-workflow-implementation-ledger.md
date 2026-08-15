# General Dynamic Workflow Implementation Ledger

Status: active implementation ledger

Date: 2026-07-27

Related: `.docs/062-general-purpose-agent-next-steps-plan.md`,
`.docs/063-agent-drafted-workflow-substrate-research.md`,
`.docs/064-adjacent-agent-workflow-orchestration-research-survey.md`, and
`.docs/065-general-dynamic-workflow-product-reassessment.md`

## Purpose

This ledger records implementation and falsifiable vertical-slice evidence for
the product sequence in `.docs/065`. It is intentionally stricter than a feature
checklist. A slice is closed only when the user journey, semantic contracts,
execution, proof, and rendered Workbench state agree.

The current product target remains:

```text
intent
  -> direct, adapt, or draft decision
  -> typed semantic workflow revision
  -> deterministic validation and semantic repair
  -> native Runic lowering
  -> policy-aware execution and durable waits
  -> verified outcome or precise blocked state
  -> saved and reusable workflow revision
```

## Current Status

| Slice | Status | Strongest current evidence | Missing proof |
| --- | --- | --- | --- |
| 0. Reproduce and measure baseline | Implemented for the initial three families | Standalone LitterBox smoke passes. One corrected real-browser GPT-5.6 Luna command passes all five matrix rows with 39/39 deterministic checks and no UI gaps. A live Luna intent-authoring command verifies an eight-node workflow with one planning and four execution calls. A novel held-out Luna suite now passes direct, capable direct-agent, exact reuse, deliberate negative selection, adaptation, and fresh drafting for research, batch, and coding against external outcome proof. | ReqLLM has no authoritative Luna pricing yet. Do not spend more provider samples on these three fixtures unless a product change or new failure mode would change the routing decision; prioritize user-attention evidence. |
| 1. Shared IR and contract-first vertical | Implemented for three verticals | Experimental IR V1, pinned contracts, exact ports, loss-reporting adapters, progressive validation, component and coding-domain lowering, hashes/source maps, native map/reduce research and bounded-batch executions, a coding mutation execution, and real-browser contract/effect review exist. The final reuse browser journey joins revision, definition, compiled, catalog, artifact, and scorecard proof in the plan and run inspector. | Keep mixed-dialect execution explicitly unsupported until a real bridge is justified. |
| 2. Typed patching and collaborative review | In progress | Pure operation batches enforce revision/hash preconditions, apply atomically, draft-validate, return affected nodes, semantic diffs, and safe inverses; accepted batches are append-only durable rows. Workbench accepts direct edits, stages durable suggested edits for explicit acceptance or rejection, applies safe inverses as new revisions, and compares any two immutable revisions. Semantic changes now render as concise Flow, Policy, Node, Proof, Decision, and Note rows by default, with canonical operation/diff JSON behind disclosure. Typed operations retained 9/9 Luna repair fidelity at 9,217 tokens versus 19,137 for DSL and 44,313 for JSON; the execution comparator was exact 6/6 with zero collateral versus whole-object repair's 4/6 exact and two collateral identity changes. A counterbalanced browser study durably records correctness, elapsed attention time, and review actions for semantic and raw-JSON arms. | The instrument and automated browser proof exist, but actual human participant evidence remains before closing the gate. |
| 3. Durable definitions, runs, and waits | Implemented for V1; broader recovery deferred | Canonical immutable revisions, append-only operation/lifecycle history, review-gated activation, stable compiled fingerprints, revision/hash-pinned Runic execution, durable runtime review waits, explicit revision-change decisions and forking, regenerable projections, and Workbench lifecycle actions now exist. Browser journeys prove edit/review/activation/fork execution, operator-requested pause/review/resume across fresh Phoenix processes, intent-drafted execution under the persisted session write policy, and selective child retry. Quarantining map mode retains successful outputs plus explicit failed-item/input-hash evidence and an accounted partial-proof summary. Resumed child output is extracted from declared ports or terminal components rather than raw-production order. Runnable validation rejects automatic retries for opaque effects; artifact writes reconcile by path/content hash. Structured coding edits now have a runtime-only unknown-after-dispatch replay path that verifies operation post-state, retains attempt provenance, and refuses unverifiable mutation replay. | Automatic structured-edit replay from the durable executor, selected sandbox reconciliation, richer internal policy gates, and artifact-format migrations remain explicit post-V1 work rather than hidden readiness requirements. |
| 4. Reusable workflow boundaries | Implemented for the initial three families | Activated revisions expose hashed public contracts; exact references are resolved and input-checked before launch; `workflow_task` creates pinned child runs with provenance; Workbench shows parent/child lineage; bounded fan-out uses native `Runic.map`. Stable invocation identities, durable outputs, retry lineage, fresh-process resume, failed-child-only map retry, and artifact reconciliation have integration proof. Novel research, batch, and coding comparisons now all pass exact reuse, negative selection, adaptation, and fresh drafting. Workbench can archive definitions while retaining immutable history and preventing routing or new launches. | Measure operator attention rather than assuming token savings equal product value. Keep general effect-level reconciliation deferred until a concrete component can prove its post-state. |
| 5. Authoring and planning optimization | Implemented for automated V1; human gate open | Strict DSL round trips through canonical IR; deterministic and real-model JSON/DSL/operation evals persist usage and diagnostics; versioned optimization candidates retain a multi-objective Pareto frontier; a three-case, three-repeat GPT-5.6 Luna local-repair suite passes 27/27 arms. Seeded semantic and topology repairs have an end-to-end execution comparator. Draft-from-intent receives the retrieved compatible catalog, emits canonical IR, and passes deterministic repair/compilation. The novel three-family Luna suite passes every routing and execution arm. Model-authored adaptations receive bounded protocol/editor correction. | Blinded human comprehension and user-attention measurement remain. Do not add optimizer machinery until those measurements reveal a routing or presentation defect. |

## Implemented Foundation

### Executable Baseline Fixtures And Sandbox Boundary

- `RunicAI.RLM.Robustness.OpsLogicFixture` now produces a real dependency-free
  Mix application, source, tests, runtime smoke, and product-shape evidence
  instead of invalid placeholder files duplicated between tests and the runner.
- Browser probes accept an injected run function without mutating global
  application state during tests.
- `mix litter_box.validate_standalone` compiles and executes a separate temporary
  Mix project against the sibling LitterBox dependency. The observed result was
  `status=ok`, backend `just_bash`, isolation `in_process_virtual`.

### Experimental Shared Workflow IR V1

The experimental shared layer under `RunicAI.Workflows` currently includes:

- `IR`, `IR.Node`, and `IR.Edge` with format version, stable id-keyed maps,
  exact node/port endpoints, policies, effects, acceptance, holes, presentation
  metadata, JSON round trips, and presentation-independent semantic hashes;
- `Catalog` with versioned and hashed workflow-facing contracts derived from
  the existing authoritative component catalog;
- adapters from assistant blueprints and coding proposals that return explicit
  loss diagnostics rather than claiming false equivalence;
- progressive `:draft` and `:runnable` validation for catalog pins, exact ports,
  assignability, occupancy, required bindings, cycles, holes, acceptance,
  critical `:any` boundaries, and stale contracts;
- homogeneous general-component lowering through the assistant compiler and
  homogeneous coding lowering through an explicit typed domain adapter into
  the coding compiler, both with compiled hashes and semantic-to-Runic source
  maps;
- explicit `unsupported_workflow_dialect` rejection for mixed graphs until a
  real cross-dialect runtime bridge exists.

The shared-path vertical tests now prove:

- a research IR with exact ports lowers `lambda_map` and `lambda_reduce` to
  native Runic map/reduce shapes, executes with a bounded test client, writes
  `reports/delivery-risk-report.md`, and satisfies its objective scorecard;
- a coding IR lowers through the domain adapter, emits a native coding Runic
  graph and source map, executes `mix compile --warnings-as-errors`, and
  satisfies its verification gate;
- a mixed component/coding graph is rejected rather than connected through an
  implicit `any` bridge.

Workbench graph review now renders a read-only contract panel with component
kind and execution shape, named input/output ports, effects, policy keys, and
acceptance conditions. Server-rendered LiveView coverage and a retained CDP
browser capture prove the projection. The same browser session also exposes the
exact durable definition, compiled artifact, and catalog lineage in the
Artifacts inspector.

### Typed Operation Transactions

`RunicAI.Workflows.Editor` provides the first pure collaborative-editing layer.
It currently supports add/replace/remove node, connect/disconnect, set/remove
argument, node or workflow policy changes, set/remove acceptance, resolve/add
hole, and node or workflow annotation. A batch:

- rejects stale base revisions and optional semantic hashes;
- edits a copy and commits all operations or none;
- runs draft validation, including exact-port compatibility, before returning;
- increments the revision once per transaction;
- returns semantic map/list diffs, affected nodes, diagnostics, and inverse
  operations where restoration is safe;
- requires explicit cascade when removing a connected node.

The authoring boundary also rejects atom/string map keys that collide after
JSON encoding. Typed operations resolve an existing atom or string key by its
canonical JSON name, preventing a patch from creating two values that a JSON or
DSL round trip would collapse.

Accepted editor batches are now stored as append-only operation rows linked to
their immutable base and result revisions. The Workbench artifact inspector now
accepts operation JSON, shows pinned versus latest revision and lifecycle state,
renders the latest affected nodes and semantic diff, and exposes safe undo,
request-review, approve, activate, revalidate, and explicit fork-to-latest
actions. Undo submits the stored inverse through the same edit-and-compile
boundary and creates a new immutable revision rather than moving a pointer or
mutating history. Candidate edits pass both the draft editor and runnable
compiler before the durable revision is created; focused proof shows an
unresolved-hole patch is rejected without adding a revision. Operation-based
suggestions remain.

Workbench revision comparison is directional and recomputed from the two
canonical immutable IR documents; it does not assume that the revisions are
adjacent or try to reconstruct state by concatenating operation logs. The view
shows exact revision and semantic-hash endpoints plus added, removed, and
changed nodes, edges, acceptance, holes, workflow policy, and metadata. A
server-rendered lifecycle test compares revision 1 with revision 4 after an
edit, immutable undo, and later edit, and rejects identical or unknown revision
selections precisely.

The retained CDP browser journey created revision 2 through the typed edit form,
selected revision 1 and revision 2 in the rendered comparison controls, and
displayed the exact `max_runtime_ms` before/after policy diff. It then continued
through review, approval, activation, and fork with no console errors and no
network failures:

`tmp/rlm_robustness/browser-workflow-revision-comparison-luna/`

Suggested edits now use a durable `workflow_edit` review request rather than a
transient UI buffer. Suggestion creation pins the immutable base revision and
hash, runs the same editor and runnable compiler preview as a direct edit, and
stores operations, affected nodes, semantic diff, result hash, compiled hash,
rationale, and proposer. Approval or a rewritten operation transaction passes
through the normal edit/compile/revise path and records the suggestion review id
in the accepted operation batch; rejection creates no revision. If another edit
wins first, approval fails with `stale_suggested_revision`, leaves the suggestion
pending, and requires an explicit rejection or a newly based proposal.

Workbench renders the complete operation and before/after semantic diff, with
separate apply, rewrite, and reject decisions. A server lifecycle test proves
acceptance, provenance, stale rejection, and no revision on denial. The real
browser journey stages `set_policy(max_steps, 10)`, reviews the policy diff,
accepts it as revision 3, and retains screenshots with zero console errors and
zero network failures:

`tmp/rlm_robustness/browser-workflow-suggested-edit-luna-v6/`

That browser run also caught a terminal-truth regression: generic review events
could reopen a completed parent agent session. Workflow-edit review request and
decision projection now preserve an already terminal parent while keeping the
review independently actionable.

The coding coordinator now prefers the same typed operation protocol after the
first generated object has a trustworthy normalized proposal shape. It adapts
that proposal to shared IR, sends validation diagnostics plus a concise editable
manifest without repeated contract bodies, applies the response through
`Editor`, lowers back through the coding-domain adapter, and runs the original
policy validator again. Revision and semantic-hash preconditions are constructed
server-side; agent-returned precondition fields cannot override them. A rejected
operation is recorded, leaves the base unchanged, and can be repaired by the
next bounded attempt. Accepted validation reports retain strategy, attempt,
operation, affected-node, hash, and semantic-diff evidence. Malformed proposal
shapes still use whole-object repair because there is no semantic base that can
be patched safely.

An opt-in live integration seeded a two-node cycle, then delegated only the
repair transaction to `openai:gpt-5.6-luna`. Luna returned a local typed edit;
the editor applied it, the coding policy validator accepted the resulting DAG,
and the test passed in one provider repair call. ReqLLM still labels Luna model
metadata as unverified, so the proof records behavior but does not invent cost:

```sh
RUNIC_AI_LIVE_WORKFLOW_REPAIR=1 \
  mix test test/runic_ai/workflows/coordinator_typed_repair_live_test.exs
```

### Durable Definition Revisions And Pinned Runs

SQLite schema version 3 adds immutable workflow definition revisions,
append-only operation batches and lifecycle events, compiled artifacts,
regenerable projections, and explicit latest/review/active revision pointers on
stable managed-workflow identities. Launch records pin the definition revision,
semantic hash, compiled artifact and hash, and catalog hash.

The first lifecycle API now proves:

- draft, revise, request review, approve/reject, activate, close, archive, and
  revalidate transitions;
- stale edit rejection without a partial revision or operation row;
- activation only after approval and compilation;
- edits to an active workflow create a new latest revision while the previous
  approved revision remains the active launch target;
- suspended/waiting runs require an explicit restart or fork decision, and a
  fork records its parent run and revision while pinning the chosen artifact;
- projections can be regenerated from canonical revision JSON; and
- a pending workflow-revision review survives closing and reopening SQLite and
  can then be approved.

`ManagedWorkflows.create_run/3` bridges to revision-pinned launch for upgraded
definitions while retaining the legacy path for definitions without an active
revision. `WorkflowExecutor` loads only the run's pinned native Runic artifact,
verifies every definition/artifact/catalog pin, records running and terminal
state through the existing SQLite Runner store, checkpoints and pauses, creates
a durable runtime review request, records the external decision, and resumes
through a newly started caller-owned `Runic.Runner`. The restart test closes the
original Runner and SQLite connection, reopens the database, approves the
pending review, resumes the in-flight runnable, and proves the original
definition and compiled hashes remain pinned through completion. Workbench run
inspection renders that exact revision and hash lineage. An operator can also
request a runtime review from the pinned-run inspector; the same durable review
card and approval path are used as workflow-authored waits.

The real-browser lifecycle fixture then exercised the user-facing definition
path rather than only server-rendered tests. From a completed revision-1 run it
submitted `set_policy(max_runtime_ms, 5000)`, compiled revision 2, requested
review, approved and activated it, and explicitly forked the old run onto the
new revision. The Phoenix server was stopped and restarted before a second CDP
capture. SQLite and the rendered inspector agreed that:

- the original run remained completed and pinned to revision 1;
- the fork remained pending and pinned to revision 2;
- revision 2 retained its parent revision and active status; and
- both browser captures had zero console errors and zero network failures.

Starting the fork after restart exposed an invalid durability assumption in the
first artifact design: serialized native Runic graphs contain VM-local compiled
regex references and closures. A safe `binary_to_term` rejected the artifact
after restart; an unsafe decode in the original process left the regex unusable.
Canonical-IR compiled artifacts now declare `recompile_from_ir_v1`. The executor
recompiles from the immutable pinned IR and workspace, verifies the regenerated
compiled hash against the run's pinned hash, and starts only on an exact match.
Opaque legacy artifacts still use the existing safe decode and return a
structured `unsafe_compiled_artifact` error instead of crashing LiveView.

The browser restart path then exposed a second process-local assumption:
presentation serializers and Runic's internal component identifiers made the
compiled fingerprint vary between BEAM instances. Compiled fingerprints now
use `stable_lowering_v2`, derived from stable semantic and native-lowering
fields rather than DOT, Mermaid, Cytoscape, or VM-local edgelists. A focused
test proves that changing only those presentation hashes leaves the compiled
fingerprint unchanged, and separate `mix run` processes produced the same hash
for the same pinned IR.

Runic's stored `ComponentAdded` events also cannot reconstruct dynamically
compiled component closures in another VM. Resume therefore starts from the
freshly recompiled immutable pinned graph, filters structural component and
reaction events, replays runtime events and fact references through the SQLite
fact resolver, and starts that reconstructed runtime state as resumed. The
canonical revision owns structure; the event and fact stores own runtime
progress. This separation is now an explicit durability contract rather than
an implementation accident.

A third real-browser capture started the pending revision-2 fork after restart,
observed its row transition to `completed`, and retained zero console errors and
zero network failures:

`tmp/rlm_robustness/browser-workflow-lifecycle-execute-luna-v3/`

Evidence directories:

- `tmp/rlm_robustness/browser-workflow-lifecycle-luna/`
- `tmp/rlm_robustness/browser-workflow-lifecycle-restart-luna/`

A separate real-browser fixture proved the runtime-wait boundary itself. In the
first Phoenix process, the browser started an exact revision-pinned run from the
Artifacts inspector, observed `running`, requested an operator review, observed
`review`, and rendered the pending approval form. Phoenix was then stopped. In
a fresh process, the browser reopened the same session, approved the review,
and observed that exact run reach `completed`. Both legs retained screenshots,
had zero console errors, and had zero network failures:

- `tmp/rlm_robustness/browser-workflow-runtime-review-luna-v7/`
- `tmp/rlm_robustness/browser-workflow-runtime-review-resume-luna-v7/`

The proof found and fixed three races that server-only tests had not exposed:
runtime reviews must remain actionable even when their parent agent session is
terminal; review-decision projection must not overwrite execution-owned run
status; and pause must synchronize initial Runner input and confirm the runner
actually stopped before returning. A terminal run that wins the pause race is
now left terminal rather than resurrected as waiting.

### Reusable Workflow Contracts And Child Invocation

`RunicAI.Workflows.PublicContract` derives or reads the public input, output,
effect, policy, and acceptance contract of an immutable revision and pins it by
contract hash. The initial JSON-schema subset rejects incompatible object,
array, primitive, required-property, property, and item shapes with an exact
path before a child run exists.

`WorkflowLibrary` resolves only active revisions and checks optional revision
id/number, definition hash, and contract hash pins. Its first deterministic
retrieval pass records all considered active candidates, input compatibility,
term-overlap evidence, the selected exact-reuse candidate, and a miss rationale.
This is intentionally a product baseline for later planner retrieval and evals,
not a claim that lexical ranking is sufficient.

`workflow_task` is now a catalog component with a `workflow_invoke` effect and
a runtime adapter. The underlying `WorkflowTask` API:

- validates input before creating a child row;
- performs an expected-revision/hash check in the same transaction that pins
  the child run, closing the resolve/activate race;
- records parent run, parent revision, parent node, exact child reference, and
  reuse decision in child provenance;
- executes through the SQLite-backed pinned-artifact evaluator;
- validates output before returning it to the parent and changes the child to
  failed if its public output contract is violated; and
- exposes bounded `workflow_map` as a real native `Runic.map`, producing one
  independently restartable and inspectable child run per item.

Focused proof rejects an integer/string input mismatch without creating a
child, invokes an exact saved revision successfully, rejects a stale revision
reference, executes two mapped child workflows through native fan-out, and
shows all three child lineages as completed. The Workbench artifact inspector
now labels child runs with their parent alongside both revisions and hashes.

SQLite schema version 4 makes logical child invocation durable rather than an
in-process convention. A workflow run may now retain its parent run and node,
stable invocation key, attempt number, superseded attempt, and recorded output.
The unique parent/invocation/attempt constraint prevents concurrent callers
from creating two rows for the same logical attempt.

`WorkflowTask` uses that state to make retry behavior explicit:

- re-entering a completed invocation returns its persisted, contract-checked
  output without restarting the workflow;
- a waiting child can be approved and resumed after both the original Runner
  and SQLite connection have been replaced;
- a failed child is not retried unless the caller or operator asks for it;
- retry creates a new attempt pinned to the exact original definition,
  artifact, compiled hash, and catalog hash; and
- native mapped invocations reuse completed siblings and restart only failed
  items, keyed by parent node, exact child reference, and input.

The compiler now injects the durable workflow store, Runner, parent run, and
parent node into a persisted `workflow_task` component when rebuilding its
parent from canonical IR. This closes the gap between a directly constructed
test graph and a saved parent workflow executed in a later process.

Three integration tests cover that boundary. One recompiles and executes a
persisted parent IR containing a real `workflow_task`. One pauses its child for
review, destroys the original Runner and SQLite connection, resumes in fresh
instances, records the output, and proves parent re-entry creates no duplicate
child. The third maps three items through a transiently failing child, then
proves the second pass executes only the failed item: completed item call counts
remain one, the failed item advances from attempt 1 to attempt 2, and the retry
supersedes the failed row while retaining all immutable pins.

Workbench routes child resumes and retries through this API rather than the
generic top-level executor. Failed, blocked, or cancelled children expose a
`Restart only this child` action and render attempt/supersession lineage. A
server-rendered LiveView test proves the action and durable output. The live CDP
journey seeded a failed child from a separate BEAM process, opened the session
in Phoenix, clicked the selective restart, and observed attempt 2 complete with
the same revision, definition hash, compiled hash, and catalog hash. The
retained capture has zero console errors and zero network failures:

`tmp/rlm_robustness/browser-workflow-child-restart-luna/`

This is invocation-level idempotency, not a blanket exactly-once claim. A
completed child will not be replayed by the parent or mapped retry, but an
effectful component that fails after an external side effect and before durable
completion still needs its own idempotency key or reconciliation contract.

### Effect Replay And Reconciliation Contracts

The workflow catalog is now contract version 2. Every component contract states
its replay strategy and whether automatic retry is allowed:

- pure deterministic components declare `safe_replay`;
- model calls declare `at_least_once` and make the possible additional call
  visible rather than pretending the response is deterministic;
- saved workflows declare `durable_invocation` and reuse their stable child key
  and recorded output;
- artifact writes declare `reconcile` with resolved path plus content SHA-256 as
  the logical key; and
- opaque tool, command, agent, and sandbox mutations declare
  `manual_reconciliation` until their adapters implement a stronger contract.

Runnable validation rejects a positive retry count or retrying scheduler preset
on an effectful component whose contract does not permit automatic retry. Draft
validation reports the same condition as a warning, so an agent or human can
remove the retry, choose a safer component, or add a real component-specific
reconciliation implementation before launch. This does not accept a decorative
`idempotency_key` string as proof when the runtime adapter cannot enforce it.

`ArtifactWriter` is the first externally mutating implementation. It computes
the content before mutation, writes through a same-directory temporary file and
atomic rename, and returns the content hash, stable logical key, and one of
`created`, `replaced_existing`, or `matched_existing`. If execution dies after
the rename but before the workflow run records completion, the next attempt
compares the existing bytes, returns `reconciled`, and does not touch the file.

The crash-window integration deliberately writes an artifact, fails the child
after that external effect, pins the file mtime, and retries the same logical
invocation. Attempt 2 reports `matched_existing`, preserves the mtime and bytes,
and completes while retaining attempt/supersession lineage. This proves one
real reconciliation strategy; it is not generalized exactly-once delivery for
arbitrary tools.

Replay semantics flow through compiler metadata into the Workbench contract
review. The UI explicitly labels `safe_replay; automatic retry allowed` versus
`manual_reconciliation; manual reconciliation required`. A live Luna-labelled
CDP session captured both states from the rendered Plan with zero console errors
and zero network failures:

`tmp/rlm_robustness/browser-workflow-replay-contract-luna/`

### Artifact And Catalog Compatibility Boundary

Pinned execution now classifies artifact compatibility before decoding or
recompiling. The runtime recognizes canonical-IR `recompile_from_ir_v1` and the
existing same-VM `native_external_fun_v1` adapter explicitly. An unknown named
format returns `unsupported_compiled_artifact_format`; it is no longer treated
as an arbitrary legacy term. Recompilable artifacts likewise reject unknown
compiled-hash formats before execution.

New intent-authored artifacts declare `catalog_compatibility:
strict_current_v1`. If their pinned catalog snapshot differs from the current
catalog, execution returns `pinned_catalog_snapshot_unavailable` with the exact
pinned/current hashes and `create_revalidated_revision` as the required action.
Legacy artifacts without that declaration retain their existing compatibility
behavior; this avoids retroactively pretending old arbitrary catalog labels are
content-addressed snapshots. A focused persistence test exercises both precise
rejections through real pending runs and a real Runner.

This is the safe block half of artifact migration. The remaining product work
is an explicit operation that re-resolves contracts, creates a new immutable
definition revision and artifact, reviews it, and forks rather than mutating a
run's historical pins.

### Intent Routing, Adaptation, And Drafting

`RunicAI.Workflows.IntentPlanner` now owns a real three-way authoring boundary
rather than treating routing as a label applied after generation:

- `direct` resolves an active compatible public contract and creates a run
  pinned to that exact definition, compiled artifact, and catalog;
- `adapt` loads the selected active revision, obtains the smallest typed
  operation transaction either from an injected deterministic fixture or the
  selected model, forks the proven IR into a separate workflow identity, and
  applies the transaction through `Editor`, runnable validation, repair, and
  compilation; and
- `draft` gives the selected model the compatible component catalog and strict
  authoring schema, canonicalizes the result, repairs deterministic defects,
  validates it as runnable, compiles it, and stores it as a reviewable durable
  definition rather than executing an unreviewed model object.

All three routes retain the request, considered candidates, compatibility and
selection reasons, catalog hash, model and usage metadata, source/base hashes,
semantic result hash, and route-specific diagnostics. Adapt additionally
retains the typed operations, affected nodes, semantic diff, and repair
history. Candidate evidence is normalized to JSON-safe durable data before it
reaches Ecto; a real browser run found that raw tuple reasons otherwise caused
the completed planning result to fail during revision persistence.

Retrieval now distinguishes two different questions that were previously
collapsed. Exact invocation validates the complete request against the declared
public input, including JSON Schema `const` and `enum`. Adaptation-base
compatibility validates a separate structural schema that preserves object,
array, required-property, property, and item shapes without pinning the prior
objective, paths, or output values. An auto-authored workflow can therefore
reject a different request for exact reuse while remaining a safe typed base
for adaptation. Undeclared contracts are neither invokable nor adaptable, and
lexical overlap alone cannot select them. A deterministic adaptation proof
changes only `max_runtime_ms`, creates a separate pending draft for the new
objective, records base provenance, and leaves the original active workflow
and revision unchanged.

Workbench exposes the authored result as one canonical proposal review. The
Plan view renders route rationale and candidates, immutable revision and
definition/catalog hashes, the executable graph and contract/effect panel, and
typed pre-run edits. An accepted edit creates another immutable revision and
supersedes the now-stale review rather than leaving two actionable reviews.
Request review, approval, activation, and pinned launch all use the same
definition lifecycle as hand-authored definitions.

Planning also has an outer deadline independent of provider timeouts. A timeout
is persisted as an error/failed projection, not a successful or forever-running
session, and no partial definition is launched.

### Intent-Drafted Browser Execution And Runtime Truth

A real isolated Workbench journey used `openai:gpt-5.6-luna` for the user
request to analyze `notes/incidents.md` and `notes/roadmap.md` and write a cited
delivery-risk report. Luna drafted this eight-node, seven-edge native component
workflow:

```text
source_discovery
  -> source_splitter
  -> source_materializer
  -> llm_map
  -> lambda_reduce
  -> llm_leaf
  -> artifact_writer
  -> objective_scorecard
```

The browser rendered the graph and exact component contracts, with
`model_call` only on the two actual model-calling nodes and
`workspace_write` only on the writer. The operator applied a typed
`set_policy(max_runtime_ms, 240000)` edit to create revision 2, reviewed the
semantic diff, approved and activated it, and created a pinned run containing
the complete original request. The final verified run is:

- run suffix: `600d337d`;
- definition revision: 2;
- definition hash: `22e7b7328f36`;
- compiled hash: `7bb16782560d`;
- catalog hash: `16284a7f64b8`;
- execution time: about 32 seconds; and
- output: `.docs/delivery-risk-report-luna-browser.md` in the isolated
  workspace.

The artifact has distinct `Summary`, `Risks`, and `Actions` sections and cites
the actual facts: retry handling caused duplicate work, remediation calls for
idempotency and alerting, the retry redesign precedes the next payment
milestone, and neither source names the required owner, checkpoint, or
acceptance criteria. It labels recommendations and inferences rather than
inventing commitments.

The first two pinned executions were retained as product-debugging evidence.
They exposed three important runtime-contract failures:

1. pinned-IR recompilation rebuilt a default workspace and lost the persisted
   session `docs_only` write policy;
2. generated scheduler policy used `on_failure: :skip`, allowing a failed
   artifact write to be followed by a false completed status; and
3. generated map/reduce prompts could ask for provenance while omitting the
   runtime source path or evidence placeholder, yielding a structurally valid
   but ungrounded report.

`WorkflowExecutor` now reconstructs workspace policy from the persisted agent
session, forces native workflow scheduler failure handling to halt, fails the
run immediately from the runner's failure callback, and refuses to let a later
completion callback overwrite failure. A regression executes the same pinned
writer under `docs_only` and deny policies: the first writes and completes, the
second fails with `runic_runnable_failed`, writes nothing, and remains failed.

`LLMMap` now supplies authoritative path and line metadata at each per-source
model-call boundary. `HierarchicalReduce` injects the actual evidence when a
drafted group or final prompt forgets `{{items}}`, without duplicating it when
the placeholder is present. Prompt-capture tests prove both invariants. This is
a component runtime guarantee: an agent may draft how to process evidence, but
cannot accidentally remove the evidence payload or its source identity.

The isolated evidence store is under `tmp/browser_intent_luna/`. The broader
live authoring command retained separately at
`tmp/workflow_intent_evals/065-intent-draft-luna-v9/report.md` passed runnable
validation and execution with one planning call, four execution calls, 10,836
reported provider tokens, 33,987 ms latency, eight nodes, and seven edges.
ReqLLM still marks Luna model metadata and pricing as unverified, so no monetary
cost is inferred.

### Live Direct, Reuse, Adapt, And Draft Comparison

`RunicAI.Workflows.IntentStrategyComparator` now evaluates routing truth and
execution proof separately. It first executes, reviews, approves, and activates
a proven base revision, then records five isolated arms:

- a short request that should remain direct;
- the exact base request that should reuse the active revision;
- a malformed request that must reject both exact invocation and adaptation;
- a related request that should adapt the structurally compatible base through
  typed operations; and
- the same related request forced through fresh workflow drafting.

Adaptation and fresh drafting use different workspaces, so a stale artifact
cannot satisfy either proof. Each authored arm retains separate planning and
execution calls, full prompts and responses, provider usage, latency, route
candidates, exact/adaptation compatibility, definition and compiled hashes,
diagnostics, and the resulting artifact in SQLite. The deterministic integration
test covers the same five decisions with injected clients and blueprints.

The clean live run at
`tmp/workflow_strategy_evals/065-intent-strategy-luna-v4/report.md` used
`openai:gpt-5.6-luna` for a research-and-cited-synthesis task. All five arms
selected the expected route and both executed arms satisfied the objective and
artifact proof:

| Arm | Author calls | Execution calls | Tokens | Latency | Verified |
| --- | ---: | ---: | ---: | ---: | ---: |
| Adapt proven revision | 1 | 2 | 3,286 | 18,384 ms | yes |
| Draft new workflow | 1 | 4 | 14,486 | 41,074 ms | yes |

For this case, adaptation saved 11,200 reported provider tokens and 22,690 ms.
That is evidence for the Slice 4 reuse hypothesis on one nearby task, not yet a
general conclusion. Held-out repetitions and the coding and batch/fan-out
families remain required.

The live development runs also exposed two boundary defects. First, the
compiler's default 30-second LLM scheduler policy wrapped an entire multi-call
`llm_leaf`, causing Luna synthesis to time out and retry even though the
provider receive timeout and workflow budget were larger. The compiler now
accepts an explicit `llm_timeout_ms`; the comparator uses 180 seconds and a
regression proves the model-node policy. Second, the eval verifier incorrectly
required level-two Markdown headings while a valid generated artifact used
level-one headings. Verification now accepts standard level-one through
level-six Markdown headings while still requiring every named section. Failed
development suites remain retained as evidence rather than rewritten.

ReqLLM labels Luna model metadata and pricing as unverified. The suite therefore
records provider token fields and latency but deliberately omits dollar cost.

### Compact DSL And Substrate Evaluation

`RunicAI.Workflows.DSL` is a strict, canonical, line-oriented projection over
IR V1. It retains stable ids, exact edge endpoints, component contract refs and
hashes, policy, acceptance, holes, and metadata while avoiding repeated
contract bodies. Parsing always re-resolves catalog pins and produces canonical
IR; the DSL is never an independent execution path. Malformed fragments report
their exact line and stale catalog pins are rejected.

SQLite schema version 3 also adds durable workflow eval rows and versioned
optimization candidates. Eval rows retain model, task family, arm, status,
provider usage, latency, prompt and response bytes, diagnostics, and artifacts.
The initial GEPA-style boundary records textual modules, ancestry, rich
feedback, multiple metrics, and a Pareto frontier instead of reducing quality,
safety, latency, and cost to one score.

The live model harness uses `openai:gpt-5.6-luna` and compares three authoring
arms through the same canonical IR and editor boundary:

- full normalized JSON;
- the compact DSL; and
- typed operation JSON plus a concise editable manifest and explicit operation
  field grammar.

Revision numbers are server-owned, so full-object and DSL candidates are
normalized to the target transaction revision before semantic comparison. The
first apparently failing run was retained as negative harness evidence: both
full representations made the exact edit but were incorrectly penalized for
not incrementing the revision. A later operation failure was also retained: a
prompt that listed operation names without their field grammar caused Luna to
emit `node` instead of `node_id`.

The corrected three-case scale suite changes one field in 1-, 6-, and 14-node
graphs and repeats every arm three times. Report:

`tmp/workflow_substrate_evals/065-substrate-local-repair-scale-luna-v5.md`

| Arm | Semantic passes | Input tokens | Output tokens | Total tokens | Total latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Normalized JSON | 9/9 | 24,927 | 19,386 | 44,313 | 67,917 ms |
| Compact DSL | 9/9 | 9,363 | 9,774 | 19,137 | 38,885 ms |
| Typed operations | 9/9 | 8,778 | 439 | 9,217 | 12,004 ms |

For these local edits, typed operations used 52% fewer total tokens than DSL,
79% fewer than JSON, and had the lowest aggregate latency. DSL used 57% fewer
tokens than JSON and remains materially more compact for full-definition
authoring. This is evidence for using typed operations as the default patch and
repair protocol, not for adopting the current DSL as a primary language. The
suite is synthetic local-repair evidence; it does not measure drafting,
topology changes, execution success, safety, or human comprehension.

The product recommendation therefore remains layered:

1. canonical IR is the versioned execution and persistence truth;
2. typed operations are the default agent/human mutation protocol;
3. generated graph, diff, and contract views are the default human review
   surface; and
4. compact DSL remains an optional full-definition projection until it wins
   the broader held-out and human evals required by `.docs/065`.

### End-To-End Repair Comparator

`RunicAI.Workflows.RepairComparator` closes the execution gap in the earlier
substrate-locality experiment. It gives whole-object JSON regeneration and
typed operation repair the same base IR, user instruction, and runnable
diagnostics, then sends both candidates through the production boundaries:

1. JSON decoding and canonical IR or operation parsing;
2. server-owned revision and semantic-hash preconditions;
3. runnable contract validation;
4. native Runic compilation;
5. execution in a separately provisioned workspace; and
6. a case-specific output/artifact proof.

Each retained row attributes failure to authoring, JSON, canonical IR,
operation shape/application, validation, compilation, execution, or proof and
records exact semantic repair, expected/candidate changed paths, collateral and
missing paths, prompt/response bytes, provider usage, and latency. Deterministic
tests cover a semantic argument fault, a missing-edge topology fault, and
malformed whole-object JSON.

Prompt failures are retained as harness evidence. In
`065-repair-topology-luna-v1`, both arms shortened typed edge endpoints to
`"node.port"`; the shared operation grammar and whole-object instructions now
state the exact endpoint object. In `065-repair-topology-luna-v2`, the typed arm
passed but the whole-object arm omitted the new edge's canonical identity; the
whole-object instructions now state that node and edge object ids must equal
their map keys. The corrected single topology run is retained in
`tmp/workflow_repair_evals/065-repair-topology-luna-v3.md`, and the semantic
argument run in
`tmp/workflow_repair_evals/065-repair-semantic-luna-v1.md`.

The bounded release comparison repeats both fault families three times with
`openai:gpt-5.6-luna`:

`tmp/workflow_repair_evals/065-repair-end-to-end-luna-v1.md`

| Arm | Verified executions | Exact semantic repairs | Collateral paths | Total tokens | Total latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Whole-object JSON | 6/6 | 4/6 | 2 | 7,399 | 20,977 ms |
| Typed operations | 6/6 | 6/6 | 0 | 3,387 | 7,531 ms |

Both arms reached runnable, compiled, executed, and proven results on every
attempt. Typed operations used 54% fewer total tokens and 64% less aggregate
latency. Median output tokens were 64 for typed operations versus 604.5 for
whole-object JSON. The two non-exact whole-object results were behaviorally
valid but selected a different stable identity for the inserted edge, which is
correctly visible as one missing and one collateral semantic path per result;
server-generated typed operations preserved the target identity exactly.

This satisfies the machine-measured part of the Slice 2 gate for these seeded
faults: operation repair is not worse on runnable/execution success, and both
output size and unrelated changes improve. It is not evidence for every graph
shape, and Slice 2 remains open until users can identify the change and reason
from the rendered semantic diff in a measured comprehension task. ReqLLM still
reports Luna as unverified model metadata, so these records include provider
tokens and latency but do not fabricate monetary cost.

### Coding Vertical Corrections Discovered By Browser Proof

Real browser execution exposed and drove these product corrections:

1. `--model` was omitted from browser-launched Workbench runs. The browser
   adapter now sends `model`, `model_provider`, and `model_id`, matching the
   Workbench form contract.
2. Three automatic child review approvals were insufficient for an ordinary
   small application. The bounded default is now 20 distinct review requests,
   consistent with the terminal runner, and duplicate resume keys are never
   approved twice.
3. Verification gates previously accepted command checks without visible
   command producers. Coding workflow validation now requires an exact upstream
   command node, including matching argv and cwd, for every
   `command_passes`, `command_fails_with`, or `runtime_smoke` check.
4. The coordinator prompt now states that verification gates observe evidence;
   they do not secretly execute commands absent from the graph.
5. The generic progress gate now includes files and risks produced by child
   workflows rather than examining only top-level context fields.
6. Command, script, and tool nodes now record workspace deltas, so files made by
   explicit scaffold or generator nodes participate in change provenance.
7. Passing deterministic acceptance suppresses superseded transient child
   warnings such as `verification was not run` and a provider failure from a
   child that was later independently verified.
8. A historical failed child no longer forces final failure after bounded
   repair when every current required check passes and the evidence contains
   both durable verification and delivery proof. An unrelated narrative or
   semantic pass remains insufficient to supersede a failed child.
9. List-form command arguments no longer crash proposal validation through an
   invalid `Map.new/1` conversion. Non-keyword lists are normalized as argv.
10. Internal child error/review observations no longer terminalize the parent
    session or workflow run. Only terminal error events fail them; automatic
    child review remains part of the active run.
11. Browser follow-ups now require a terminal first attempt and use the
    rendered selected-session status rather than a fixed five-second grace or
    historical `Agent finished` text. The runner also waits for the current
    run rather than accepting an older final event.
12. Robustness reports retain attempt count, ordered run-status history,
    completed repair-attempt count, and provider/planner/validator/compiler/
    runtime/proof/UI failure attribution. Recovered internal failures remain
    visible rather than being flattened into a clean pass.

Focused evidence includes 81 coding RLM tests, the shared IR tests, 41 robustness
tests, persistence projection regressions, and warning-clean compilation. The
current repository-wide regression run passes 1,083 tests with zero failures
and three intentional opt-in live-test skips. The durable child focused set
now includes the Workbench action, restart-spanning resume, partial fan-out
retry, and failure-after-artifact-effect reconciliation.

## Browser Evidence And Interpretation

### Invalid Baselines Retained As Negative Evidence

The first `065-slice0-browser-baseline` report returned 1/5 because the rendered
Workbench defaulted to `openai:gpt-5.4-mini`, and OpenAI returned HTTP 429
`insufficient_quota` before proposal generation. Anthropic independently
reported insufficient credit. This is provider availability evidence, not a
workflow-quality score.

The first Google rerun also returned 1/5 because the browser request only set
the combined model string. Workbench correctly normalizes from provider and
model-id fields and therefore selected its OpenAI default. The persisted events
proved the mismatch. This run is harness-contract evidence, not a product
baseline.

### First Valid Complete Vertical

Command:

```sh
mix runic_ai.rlm.robustness \
  --scenario empty_app_creation \
  --lane browser_tidewave \
  --label 065-empty-gemini3 \
  --browser-ui-launch \
  --browser-ui-capture \
  --trace-live \
  --model google:gemini-3-flash-preview
```

Report:
`tmp/rlm_robustness/reports/rlm-robustness-matrix-065-empty-gemini3.md`

Observed result:

- matrix row: pass;
- deterministic checks: 11 pass, 0 fail;
- browser lane and judge: pass;
- Workbench session: completed;
- objective scorecard: `objective_satisfied`;
- explicit proposal nodes included scaffold, implementation, compile, test,
  runtime smoke, and final verification stages;
- browser UI checks: no failures;
- final execution reached satisfaction only after deterministic repair and
  re-verification.

This proves one repository-mutation journey, not the general workflow product.
It also shows why the layers must be evaluated together: earlier versions could
create correct files while reporting failure, or could show a requested model
while executing a different one.

### GPT-5.6 Luna Five-Shape Browser Baseline

After OpenAI credits became available, the complete current browser matrix ran
with `openai:gpt-5.6-luna`:

```sh
mix runic_ai.rlm.robustness \
  --matrix general_dynamic_workflow \
  --lane browser_tidewave \
  --label 065-slice0-gpt56-luna \
  --browser-ui-launch \
  --browser-ui-capture \
  --trace-live \
  --model openai:gpt-5.6-luna
```

Report:
`tmp/rlm_robustness/reports/rlm-robustness-matrix-065-slice0-gpt56-luna.md`

The empty-app, existing-app, research-report, and denied-review rows passed.
All five rows passed every deterministic workspace check and every browser UI
check. The refactor row nevertheless ended failed because its implementation
child exhausted its local budget before repair, then bounded repair produced a
correct four-file workspace and passing tests, but final scorecard derivation
continued to prioritize the stale failed child result.

The scorecard rule is now narrower and outcome-oriented: a failed child may be
superseded only when every current required acceptance check passes and the
evidence includes both durable verification, such as a passing command, and
delivery evidence. A semantic or narrative pass alone still cannot mask a
failed child. The focused post-fix browser rerun passed 8/8 with a completed,
objective-satisfied session and no UI gaps:

`tmp/rlm_robustness/reports/rlm-robustness-matrix-065-refactor-gpt56-luna-proof-fix.md`

The opt-in disposable-project coding smoke has also been moved from the old
GPT-5.4 Mini fixture to Luna. A live run inspected the broken Mix project,
applied a workspace-scoped patch through the required tool, reran the test
tool, and passed. The provider call is operational, but ReqLLM 1.16 still
reports Luna as unverified LLMDB metadata, so model pricing and capability
metadata remain unavailable rather than estimated.

A first post-fix five-row report retained as
`065-slice0-gpt56-luna-final` passed four rows but correctly failed the
existing-app row. It exposed two independent defects:

- list-form `argv` crashed the validator on the first attempt;
- a fixed five-second browser grace submitted the same-session follow-up while
  the first run was still active, and the evidence snapshot could stop on a
  historical final event.

After fixing argv normalization, parent-session terminal truth, browser
follow-up sequencing, and evidence-history reporting, the focused real-browser
rerun passed 10/10 deterministic checks, judge pass, completed both attempts in
order, and reported no UI gaps:

`tmp/rlm_robustness/reports/rlm-robustness-matrix-065-existing-gpt56-luna-terminal-truth.md`

Its initial attempt completed before the follow-up began. The session retained
three internal repair completions and both workflow runs ended completed.

The subsequent corrected one-command matrix is:

`tmp/rlm_robustness/reports/rlm-robustness-matrix-065-slice0-gpt56-luna-sequenced-final.md`

Observed result:

- five of five matrix rows pass;
- 39 deterministic checks pass and none fail;
- every judge passes and every browser lane has zero UI gaps;
- empty-app and refactor each expose one repaired runtime observation instead
  of hiding it; existing-app exposes three completed internal repairs;
- existing-app records `completed -> completed` across two strictly sequenced
  attempts;
- denied-review records the expected blocked workflow-run status while the
  matrix treats honoring the denial as product success;
- all other workflow runs end completed, with no false-running terminal row.

This closes the one-command, visible-terminal-state, and failure-layer portions
of Slice 0. The broader Slice 0 comparator/fault/cost work remains open.

### Shared-IR Contract And Revision-Lineage Browser Proof

The repeatable fixture `priv/robustness/seed_workflow_contract_fixture.exs`
creates a terminal session, shared-IR compile summary, reviewed and activated
durable definition, compiled artifact, and revision-pinned completed run. The
CDP browser harness captured both the Plan and Artifacts views from that same
live session:

`tmp/rlm_robustness/browser-contract-lineage-luna/`

Observed browser evidence:

- the Plan DOM renders `Proposal contract review`, both components, named
  inputs and outputs, `workspace_write`, the review policy, and `compile
  passes` acceptance;
- the Artifacts DOM renders `revision 1`, the exact definition-hash prefix,
  compiled-hash prefix, catalog-hash prefix, and completed run status;
- the selected session status is `completed`;
- both full-page screenshots were retained; and
- console errors and network failures were both zero.

This closes the browser-review proof gap for the current two shared-IR
verticals. It does not yet prove editing or activation through browser actions.

### Provider Retry Classification Evidence

The Google free-tier failure identified its quota as
`GenerateRequestsPerDayPerProjectPerModel-FreeTier` inside nested response
metadata while the human message also said to retry in roughly one minute.
Retry classification now inspects structured response diagnostics and treats
per-day or billing/credit exhaustion as permanent. Temporary 429 windows still
honor bounded retry hints. This prevents a permanent daily limit from consuming
two extra calls and about two minutes per scenario.

### Bounded-Batch Golden Product Journey

The third `.docs/065` golden family now has both deterministic and product-level
proof.

`RunicAI.Workflows.VerticalTest` constructs a canonical batch IR that reads four
CSV rows, parses them, lowers `record_map` to native `Runic.map`, lowers
`lambda_reduce` to native `Runic.reduce`, aggregates the results, writes a
Markdown artifact, and satisfies its objective scorecard. It asserts four map
calls and at least one reduce call rather than inferring fan-out from graph
shape.

The Workbench integration journey begins at the natural-intent form, uses the
real router, adapter, validator, compiler, revision store, review lifecycle, and
runner, then proves:

- the generated review graph exposes `tabular_parser`, `record_map`, and
  `lambda_reduce`;
- approval and activation precede a revision-pinned run;
- all four records execute through map and aggregation;
- the durable root run completes with a verified artifact and scorecard; and
- the containing Workbench session reaches `completed` rather than remaining in
  its earlier review or running projection.

A real browser journey used `openai:gpt-5.6-luna` for the initial draft:

`tmp/rlm_robustness/browser-batch-golden-luna/`

The retained browser record reports status `ok`, a completed pinned workflow
run, visible native map focus, successful approval and activation, a 446,092-byte
screenshot, zero console errors, and zero network failures. The generated
`.docs/batch-transformation-summary.md` includes all four source records. The
capture predates the session-terminal projection fix and therefore preserves
the surrounding session at review even though its workflow run completed; the
post-fix LiveView integration test is the stronger evidence for terminal session
truth.

### Stable Compiled Identity, Portable Output, And Catalog Migration

The batch journey exposed that a compiled fingerprint differed between fresh
in-memory IR and its JSON-restored immutable revision. Compiled hashing now
canonicalizes struct maps, map keys, atom values, and nested collections before
hashing. A focused compiler test proves the fingerprint survives the canonical
JSON persistence boundary.

General workflow completion now carries a compact execution descriptor into the
Runner callback, extracts the component or coding result, converts it to a
portable JSON-shaped term, and stores it in `workflow_runs.output_blob`. A fresh
BEAM decoded an exact-reuse batch run and recovered:

- revision `1` and its pinned compiled hash;
- trigger `intent_reuse`;
- four `record_map` calls and one `lambda_reduce` call;
- the completed artifact path; and
- `objective_satisfied`.

Catalog migration is now an explicit lifecycle operation. It revalidates and
recompiles a stale definition into a new immutable revision with current catalog
and compiled hashes, records `catalog_migrated`, and returns through review. The
old active revision and old run pins remain unchanged until the new revision is
approved and activated. Persistence and LiveView tests cover both boundaries.

### Held-Out Batch Strategy Evaluation

`mix runic_ai.workflow_strategy_eval` now accepts `--family research|batch`.
The batch family uses a proven deterministic base, a held-out operational queue
request, incompatible negative input, isolated workspaces, live Luna authoring,
native execution, and content proof requiring the requested heading and all four
record identities.

Three samples are retained rather than discarding early failures:

- `065-intent-strategy-batch-luna-v1` exposed a string-valued acceptance edit
  and an overly narrow artifact verifier;
- `065-intent-strategy-batch-luna-v2` exposed malformed adaptation JSON and a
  fresh-draft repair exhaustion; and
- `065-intent-strategy-batch-luna-v3` routed direct, exact reuse, deliberate
  negative selection, adaptation, and fresh drafting correctly. Adaptation
  repaired once, executed, and verified at 4,010 tokens and 11,262 ms. Fresh
  drafting used 10,664 tokens and 34,313 ms, executed successfully, and produced
  a complete four-row Markdown table.

The v3 report initially marks fresh drafting failed because the old verifier
recognized `id=1` prose but not a Markdown table cell such as ``| `1` |``. The
verifier now accepts both semantic renderings, has focused positive and negative
tests, and regrades the retained v3 draft artifact as `:ok` without another
provider sample. The historical report remains unchanged so the false-negative
history is not rewritten.

The failures caused two bounded product fixes rather than prompt-only tuning:
one correction attempt for malformed adaptation protocol JSON and one correction
attempt for a decoded transaction rejected by the typed editor. Both have
deterministic tests. Provided operation batches remain deterministic and are not
silently model-rewritten.

### Held-Out Coding Strategy And Direct-Agent Evaluation

The repository-change family now runs six isolated arms: direct routing, a
capable direct coding agent, exact reuse, incompatible negative selection,
adaptation of a proven coding workflow, and fresh workflow drafting. The direct
agent and workflow arms use the same Luna model and the same external semantic
proof; the workflow arms additionally require their declared objective
scorecard. This keeps the direct control capable without granting it credit for
workflow-internal metadata it was never asked to create.

The retained run at
`tmp/workflow_strategy_evals/065-intent-strategy-coding-luna-v8/report.md`
passed all six arms:

| Arm | Author calls | Execution calls | Tool calls | Tokens | Latency | Verified |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Direct coding agent | 0 | 8 | 8 | 39,778 | 14,074 ms | yes |
| Adapt proven workflow | 1 | 0 | 0 | 1,356 | 4,272 ms | yes |
| Draft and execute workflow | 1 | 5 | 7 | 28,644 | 19,647 ms | yes |

This result supports a pragmatic routing policy rather than a claim that
workflow orchestration always wins. Exact reuse remains effectively free at
authoring time. Adaptation is the clear best path when a compatible proven
workflow exists. For a novel change, fresh workflow drafting used 11,134 fewer
reported tokens than the direct agent but took 5,573 ms longer and required a
reviewable intermediate definition. Whether that review is benefit or burden
depends on task risk and operator attention, which the next usability slice
must measure.

Retained earlier samples exposed product-boundary defects that are now covered
by regression tests: a nested workspace inherited the parent repository's Git
status; provider tool operations arrived as a JSON-encoded string; a useful
module was rejected because the verifier assumed one filename; and a partial
acceptance replacement erased executable stop-condition fields. Workspace Git
tools now require the selected workspace to own its `.git` root, operation
arguments are normalized against typed tool schemas, verification is semantic
rather than filename-specific, and typed acceptance replacement preserves its
lowering contract or is rejected with repair diagnostics.

### Novel Three-Family Strategy Evaluation

The strategy evaluator now has a distinct `--scenario novel` fixture for each
golden family. These are different objectives and artifacts from the proven
bases rather than another replay of the examples used to build the paths:

- research produces a go-or-hold payment milestone decision memo;
- batch produces a complete team ownership index from four records; and
- coding adds `DemoHealth.health/0` returning `{:ok, 42}`.

The retained GPT-5.6 Luna reports all pass direct routing, a capable direct
agent, exact reuse, incompatible negative selection, adaptation, fresh drafting,
native execution, and external artifact verification:

| Family | Direct-agent tokens / latency | Adapt tokens / latency | Draft tokens / latency |
| --- | ---: | ---: | ---: |
| Research | 15,006 / 9,932 ms | 4,899 / 12,093 ms | 11,575 / 35,851 ms |
| Batch | 21,224 / 11,983 ms | 2,478 / 9,712 ms | 4,895 / 17,204 ms |
| Coding | 26,499 / 11,003 ms | 1,552 / 5,548 ms | 67,883 / 27,833 ms |

Evidence is retained under:

- `tmp/workflow_strategy_evals/066-novel-research-luna-v2/`
- `tmp/workflow_strategy_evals/066-novel-batch-luna-v5/`
- `tmp/workflow_strategy_evals/066-novel-coding-luna-v1/`

The early novel samples are also retained because they found product faults,
not merely model variance. Direct-agent review policy initially handicapped the
control despite the evaluator already providing isolated write roots. A batch
verifier rejected a valid `work_item=ID` rendering. More importantly, a native
map feeding an ordinary step before reduce compiled into a stalled graph that
was incorrectly reported successful, and `record_map` trusted the authored
prompt to mention each source record rather than supplying the authoritative
record itself.

The resulting bounded fixes are now contracts and regressions:

- a native map with downstream work must feed its native reduce directly, and
  a reduce must have a direct native-map parent;
- a completed evaluation requires a non-nil terminal component output, with a
  structured `workflow_stalled_before_terminal` failure otherwise;
- deterministic grouping is described as parser-to-group, while per-record
  mapping is map-to-reduce-to-synthesis; and
- `record_map` always appends compact authoritative record data and provenance
  to the model input even when an authored prompt omits a record placeholder.

The three passing novel fixtures close the automated held-out gate for the
initial families. They do not justify universal graph drafting. They support a
route order of exact reuse, compatible adaptation, and then fresh drafting,
with direct execution retained for short or low-reuse objectives. No additional
provider repetitions are warranted until a product change, new family, or
observed failure could change that decision.

### Unified Workbench Product Journey

One real-Chrome journey now proves the product continuity that was previously
split across authoring, lifecycle, execution, and reuse captures. Using a new
release-readiness batch objective and GPT-5.6 Luna, the ordinary Workbench
composer:

1. routed to a fresh draft because no exact active revision matched;
2. showed the typed `record_map` and `lambda_reduce` proposal for review;
3. approved and activated immutable revision 1;
4. launched and completed its pinned run;
5. produced `.docs/release-readiness-index.md` with all four source records,
   row provenance, blockers, and a satisfied objective scorecard; and
6. opened a second ordinary composer session with the same intent and `auto`
   routing, selected the proven revision, and completed a separate
   `intent_reuse` run.

The browser harness now has a reusable `workflow_exact_reuse` continuation that
requires the second session to render `Proven workflow selected` and a completed
run row whose lineage includes `intent_reuse`. The retained first capture has a
431,049-byte screenshot, zero console errors, and zero network failures:

`tmp/rlm_robustness/browser-product-journey-luna-v1/evidence/`

The journey exposed one final projection contradiction rather than being
accepted on run status alone. The session and persisted run were completed, but
the Live Progress objective still showed the earlier `running` value and the
implementation and verification phases said that no evidence existed. Session
terminal truth now supersedes stale running objective progress. Portable
workflow output is summarized into each run projection, and the plan derives
completed pinned execution plus satisfied acceptance from that authoritative
run output when no lower-level terminal event exists.

The post-fix Chrome capture renders all of these facts together:

- planning: `Proven workflow selected` with the retrieval rationale;
- implementation: `Pinned workflow execution completed`, revision 1,
  `intent_reuse`;
- verification: `Acceptance proof satisfied`, one artifact, nine nodes, four
  mapped records, component dialect;
- live objective: `completed`; and
- artifact inspector: `OBJECTIVE_SATISFIED` plus the exact output path.

The capture again has zero console errors and zero network failures:

`tmp/rlm_robustness/browser-product-journey-luna-v1/projection-fixed-evidence/`

Focused LiveView and projection regressions cover terminal-over-stale progress,
atom/string portable output normalization, absent optional proof fields, plan
phase derivation, and the rendered proof card.

### Human Review Projection And Counterbalanced Study

Workbench no longer makes raw JSON the default collaborative review surface.
Typed edit suggestions, latest operation batches, and immutable revision
comparisons now use `SemanticDiffPresenter` to render operator-facing changes
under stable semantic categories such as Flow, Policy, Node, Proof, Decision,
and Note. The canonical typed operations and diff remain available in a
disclosure and remain the only executable/auditable truth; the prose projection
is never parsed back into semantics.

`/workflow-review-study/:case_id` provides a small counterbalanced evaluation
surface. A participant sees each case in exactly one arm and receives the other
arm on the second case. The surface starts timing only when the participant
begins review, asks three fixed-answer questions, and persists correctness,
elapsed attention time, and action count as `workflow-review-comprehension-v1`
rows in the existing workflow eval ledger. The two initial cases cover:

- expanded write access plus unsafe retries around an opaque mutation; and
- inserting a verifier node, rerouting data flow, and adding completion proof.

The real Chrome runner now supports this study mode and retains the assigned
representation before answers, the result state, DOM snapshots, screenshots,
console events, and network events. The latest isolated browser evidence under
`tmp/browser_workflow_review_study/evidence/` completed one semantic and one raw
JSON arm, recorded 3/3 fixture answers for both, and had zero console errors and
zero network failures. These scripted answers prove rendering, counterbalancing,
submission, scoring, and durable measurement. They do **not** prove that humans
understand the semantic projection faster; participant results are still
required for that claim.

Study rows now identify `human` versus `scripted` participants. The reporting
path deduplicates repeated submissions to the latest participant/case row and
excludes scripted IDs and explicitly scripted captures by default. It reports
complete two-case participants plus correctness, median comprehension, median
elapsed attention, and median review actions for each arm:

```sh
mix runic_ai.workflow_review_study_report
mix runic_ai.workflow_review_study_report --json
```

The current report intentionally says `Human participants: 0`; automated proof
is no longer able to contaminate the open human-readability gate. To run a
participant through the study using the same Workbench SQLite store:

```text
http://localhost:4000/workflow-review-study/unsafe-write-retry?participant=operator-01
```

The completion screen links to the participant's counterbalanced second case.
Use a new stable participant id for each operator. Browser automation should add
`source=scripted` or use a `browser-proof-` participant prefix.

### Product-Critical Fault Boundary Closure

The narrow fault audit found that stale lifecycle review and opaque mutation
retry policy were already enforced, but lacked one explicit approval regression
and the remaining retrieval/map cases were materially incomplete.

- Exact reuse no longer equates lexical overlap with semantic identity. It now
  requires the same normalized objective in addition to public input contract
  compatibility. Adaptation separately rejects intent-risk changes such as
  negation or newly destructive/deployment/publication actions. A high-overlap
  `Do not analyze support tickets` fixture has compatible input schemas but is
  neither executed nor adapted; it routes to a new draft with an
  `intent_risk_mismatch` reason.
- `WorkflowTask.map_workflow/4` now supports
  `on_item_failure: :quarantine`. Successful items retain child/output/attempt
  proof while a failed item returns stable input hash, normalized failure, and
  retryability instead of disappearing. `summarize_map_items/1` reports
  `completed`, `partial`, `failed`, or `invalid`, counts every item, retains
  quarantines, and states whether all items completed. The integration fault
  proves two successful outputs plus one retryable quarantine, then retries
  only that failed logical child.
- The quarantine run exposed an older output-integrity defect: a resumed child
  used `List.last(raw_productions)`, which could select its input rather than
  terminal output. Durable child extraction now honors declared output ports or
  derives terminal workflow components. The restart/resume/reuse proof again
  returns the contract-checked integer output.
- Revising a workflow with a pending definition review cancels the old review,
  clears `review_revision_id`, and causes a subsequent approval attempt to fail
  with `stale_lifecycle_revision`; no revision is activated.
- Command, agent, generic tool, and sandbox mutation contracts remain
  `manual_reconciliation`, and runnable validation forbids automatic retries.
  Structured coding `:edit` is now the narrow exception: its adapter exposes a
  runtime-only `unknown_after_dispatch` replay path, validates a durable prior
  attempt identity and increasing attempt number, and compares every operation
  with its requested post-state. Update, delete, and move replay require the
  original SHA-256 hash; a missing hash or conflicting current state blocks
  without overwriting. Create replay uses path plus desired-content hash. The
  fault tests prove a discarded-success replay leaves mtime unchanged, a
  partially applied two-operation patch applies only the missing operation,
  and invalid provenance or conflicting state is rejected. The LLM-facing tool
  schema cannot request this path.
- The catalog advertises this conditional reconciliation for coding `:edit`
  but keeps `automatic_retry?` false. The durable executor does not yet persist
  and inject the authoritative unknown-after-dispatch context, so this is a
  usable component adapter contract rather than a generalized exactly-once or
  automatically recovered mutation claim.
- A verifier-disagreement regression creates a plausible artifact and supplies
  a positive agent verifier report while a required deterministic function
  check fails. The workflow remains `objective_incomplete` and emits a repair
  need; the valid-looking file and positive report cannot override missing
  acceptance proof.

### Current Verification Baseline

The post-change full suite result is:

```text
1113 tests, 0 failures, 3 skipped
```

The suite includes focused compiler identity, portable workflow output,
catalog migration, batch and coding lowering/execution, intent review/run,
terminal session projection, adaptation protocol repair, direct-agent comparison,
workspace isolation, semantic review projection, counterbalanced comprehension
measurement, browser persistence, risk-aware retrieval, quarantined partial map
proof, stale approval, terminal output extraction, and artifact-verifier
coverage, structured-edit unknown-completion reconciliation, and verifier
disagreement. It also covers native map/reduce topology, terminal-output truth,
and authoritative per-record model input added after the novel held-out batch
evaluation. The final two regressions cover terminal session truth over stale
objective progress and portable workflow output rendered as plan and artifact
proof. The human-study reporting regression verifies arm summaries and excludes
scripted browser evidence from human participant counts.

## Product Readiness Audit

The product spine is implemented, but the broader-use gate in `.docs/065` is
not yet closed. The gate says every capability must hold across all three golden
families and must justify workflow overhead against a direct-agent baseline.

| `.docs/065` readiness requirement | Current evidence | Verdict |
| --- | --- | --- |
| Justified direct, adapt, or draft decision | Research and held-out batch five-arm comparisons; retained coding six-arm Luna comparison; deterministic router tests | Proven across the three golden families |
| Understandable nodes, ports, effects, policies, and acceptance | Shared IR, generated review views, semantic change projection, contract/browser captures, counterbalanced study instrument | Partial: the product surface and measurement path are proven; blinded human participant results remain open |
| Patch a small semantic change with immediate diagnostics | Typed operations, durable suggested edits, inverse revisions, adaptation repair | Proven technically; human error-identification study remains open |
| Approve a runnable immutable revision | Workbench review, approval, activation, and revision/hash pins | Proven |
| Execute native Runic with LitterBox-backed effects where needed | Research and batch native map/reduce; coding robustness matrix uses LitterBox | Proven across the three execution families, though not through one homogeneous dialect |
| Survive restart or delayed review | Fresh-process runtime-review resume, child resume/retry, persisted pinned artifacts | Proven |
| Show verified output, safe wait, or precise failure | Objective scorecards, denied-review browser row, durable output, risk-aware retrieval miss, explicit partial/quarantined map proof, blocked diagnostics, positive-agent-versus-failed-deterministic-verifier regression | Proven for the prioritized retrieval, map, review, retry, and narrow verifier-disagreement faults |
| Save and rerun exact definitions with proof history | Immutable definitions, exact reuse, fork/rerun, linked run and child lineage; one Chrome journey now drafts, activates, runs, then auto-routes the same intent to a distinct completed `intent_reuse` run | Proven |
| Reuse a proven workflow when its public contract matches | Exact retrieval and contract checks; research, batch, and coding comparisons | Proven across the three golden families |
| Beat or justify cost versus a direct agent | Coding six-arm control: all outcomes verified; adaptation 1,356 tokens, draft 28,644, direct agent 39,778; direct agent was faster than fresh draft | Partial: capable baseline exists and supports conditional routing; operator-attention comparison remains open |

The older `.docs/062` completion criteria are largely represented by the same
evidence, but they are not a substitute for the stricter `.docs/065` gate:

| `.docs/062` criterion | Verdict |
| --- | --- |
| Launch from Workbench using natural intent | Proven by research and batch intent journeys |
| See the selected or generated plan before execution | Proven by review-state browser and LiveView evidence |
| Approve or reject with visible phases, policies, budgets, runtimes, and mutation gates | Proven across contract, lifecycle, runtime-review, and denied-review journeys |
| Watch parent and child progress without raw event payloads | Proven by Workbench projections and child lineage/restart journeys |
| Inspect sandbox proof, objects, diffs, command output, reviews, and completion proof | Proven by the coding robustness matrix and Workbench surfaces |
| Complete only with a satisfied scorecard or precise blocked state | Proven for the exercised completion and denial paths |
| Save a workflow or component for reuse | Proven for immutable workflow definitions and promoted components |
| Rerun with linked run and proof history | Proven by exact reuse, forks, and parent/child lineage |

The strict 062/065 closure audit found one after-run requirement that the earlier
table had overstated: persistence supported `archive/3`, but Workbench did not
offer the action. Proposal and run inspectors now expose `Archive workflow`.
Archiving appends the lifecycle event, retains immutable revisions and existing
pinned run history, removes edit and launch controls, excludes the definition
from retrieval, and causes authoritative new launch attempts to return
`no_active_revision`. The intent-to-run LiveView journey now verifies the action,
the retained archived projection, and absence of a new-launch control.

The coding-family routing gap, first capable direct-agent control, one concrete
structured-edit reconciliation adapter, and the narrow false-completion fault
are now closed. Novel held-out intent evidence is also complete for the three
initial families. This ledger remains active because collaborative human review
has not yet been measured and durable automatic mutation recovery is
deliberately not enabled.

## V1 Product Boundary Decision

The automated evidence is sufficient to stop expanding the substrate and make
an explicit initial product cut. This boundary is intentionally smaller than a
universal orchestration platform while preserving the complete user journey in
`.docs/065`.

### Ship As The Product Spine

- Natural-language intent routing among direct execution, exact reuse,
  compatible adaptation, and fresh workflow drafting.
- The versioned typed IR as the only semantic definition, serialized as
  canonical JSON and pinned to exact catalog contracts.
- Typed operations as the agent and human mutation protocol, with immutable
  revisions, semantic diffs, validation diagnostics, and review decisions.
- Generated semantic summaries, graph views, Mermaid, and disclosed raw JSON
  as projections; none are alternate executable truths.
- Deterministic validation and lowering into the supported native Runic shapes,
  including sequential flow, independent branches, map/reduce, acceptance, and
  durable review waits.
- SQLite-backed definitions, compiled identity, runs, waits, artifacts,
  scorecards, child lineage, exact rerun, and restart recovery.
- The research, bounded-batch, and repository-change families as the supported
  proving set, while allowing catalog components to compose into nearby tasks.

### Defer Until A Measured Need

- A text DSL as a primary authoring or storage format. Keep its round-trip and
  eval implementation as research evidence, not a second product contract.
- DOT, PNG, JPEG, or multimodal graphs as an editing substrate. They remain
  optional generated views after a user study demonstrates an attention gain.
- Mixed assistant/coding dialect execution. Keep the explicit compiler error
  until one cross-domain workflow justifies a typed bridge.
- Arbitrary cycles, runtime graph mutation, recursion, saga/process-manager
  generalization, CRDT collaboration, and universal distributed scheduling.
- GEPA-style continuous optimization. Retain eval records and Pareto candidates,
  but do not auto-promote prompts or workflows before outcome and operator-
  attention signals are trustworthy.
- Automatic recovery for opaque commands, agents, tools, or sandbox effects.
  Add reconciliation only component by component when post-state is provable.

### Remove From The Product Promise

- Raw JSON as the default collaborative review experience.
- A workflow for every request, including cosmetic one-node graphs.
- Lexical similarity as sufficient evidence for exact reuse or safe adaptation.
- Graph compilation, fluent final text, or an agent self-report as proof of
  successful completion.
- General exactly-once mutation claims. V1 promises durable attempt history,
  explicit uncertainty, review, and narrow reconciled effects only.

### Coding First-Prompt Recovery Evidence

The general coding path now preserves provider-native tool calls when ReqLLM
streams a response instead of rebuilding a text-only assistant message. Eager
and streamed results project bounded generation evidence into child results and
durable `child_agent_completed` events: requested and response model, finish
reason, usage, tool choice, tool-call count, provider ids, and selected provider
metadata. Provider failures that occur before a response retain status, reason,
body preview, requested model, retryability, and fallback route.

Required-tool mutation turns receive bounded recovery rather than an
objective-specific exception. A tool-free pre-tool result follows the existing
retry policy and may then use one configured alternate model. Normal optional
answers and post-tool final answers do not enter this recovery path. Permanent
provider-account failures do not switch models, consume child no-op repairs, or
enter the outer coding repair loop because no prompt or workspace edit can
repair them.

The unchanged Filix first prompt was rerun in the ignored workspace
`tmp/operator_evidence/filix-first-prompt-20260815-v13/` using Sol for proposal
and judging, Terra for implementation, and Sol as the bounded implementation
fallback. It produced no files because both a direct minimal ReqLLM probe and
the workflow calls returned OpenAI HTTP 429 `credit_balance_exhausted`. This is
provider-account evidence, not a model-quality or workflow-reliability result.
Repeat clean trials only after provider credit is restored; then require fresh
project-native formatter, compile-with-warnings, test, and runtime-smoke proof
for every trial.

This decision makes the next product question concrete: can a technical
operator understand and safely approve the generated semantic plan with less
attention or fewer mistakes than the canonical JSON view? If not, improve the
review projection rather than inventing another execution substrate.

## Immediate Next Work

1. Run the two-case counterbalanced review study with actual operators. Compare
   correctness and median elapsed attention time by arm; do not count the
   scripted browser fixtures as human evidence.
2. Join those measured review actions and elapsed attention time to verified
   workflow outcomes so orchestration routing can account for user attention,
   not only provider usage. Avoid more live-model repetitions unless they would
   change that routing policy.
3. If automatic coding-edit recovery proves worth shipping after the human
   attention measurement,
   persist the
   unknown-after-dispatch attempt record in the durable executor and inject it
   into the structured edit adapter. Do not generalize to opaque tools or
   sandboxes without a similarly enforceable component-specific proof.

## Slice Closure Rule

No row is considered passing merely because files exist, a graph compiles, or a
final message sounds complete. Closure requires agreement among canonical
definition, validation, compiled graph, execution events, objective proof,
durable state, and the user-visible Workbench projection. Provider or harness
failures remain recorded but are not silently counted as agent-quality results.
