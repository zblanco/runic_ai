# Configurable AI Service Migration Use Case Exploration

Status: exploration / product design note

Date: 2026-05-15

Scope: configurable RunicAI workflows for incrementally migrating a large JSON
API service from another language/framework into Elixir and Phoenix, with
contract-backed verification, human review, route-by-route cutover, and durable
project knowledge.

Overall this looks like a vertically targeted AI software factory tuned to work for a specific kind of JSON API migration project.

## Motivated By

- Real contractor-style service rewrite projects where the expensive work is
  not just writing new code, but discovering the old system's behavioral
  contract, proving compatibility, and safely moving traffic over time.
- The need for RunicAI workflows that can operate over a large repository,
  decompose scope, run many coordinated agents, persist grounded findings, and
  produce durable artifacts that humans can review and rely on.
- The existing RunicAI direction in:
  - `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
  - `.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md`
  - `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`
  - `.docs/039-phoenix-liveview-local-agent-workbench-plan.md`
  - `.docs/043-hermes-style-agent-tool-surface.md`
- OpenAPI Specification v3.2.0, currently published at
  <https://spec.openapis.org/oas/latest.html>, as the public contract artifact
  for HTTP API shape, paths, operations, parameters, request bodies, responses,
  schemas, examples, security, and extension metadata.

## Thesis

The valuable product is not "AI rewrites an API in one shot." The valuable
product is a migration operating system:

```text
existing service + repo + runtime access + target Phoenix conventions
  -> grounded API/domain/behavior inventory
  -> OpenAPI plus RunicAI migration knowledge base
  -> route-by-route migration backlog
  -> one verified Phoenix slice
  -> repeated parallel slices in isolated worktrees
  -> reviewed PRs
  -> proxy/load-balancer cutover plans
  -> feedback into the knowledge base for the next agents
```

RunicAI is well-shaped for this because the work is naturally graph-shaped:
source discovery, route inventory, dataflow tracing, schema extraction,
side-effect cataloging, test generation, fixture backfill, code generation,
HTTP diffing, review, repair, and rollout decisions are separate but connected
workflow nodes.

The migration must stay contract-first. The old service is the source of truth
until a route has enough evidence to move traffic. A generated Phoenix endpoint
is not done because it compiles; it is done when it behaves compatibly for known
inputs, tested fixtures, realistic data, failure cases, auth policy, side
effects, and consumer expectations.

## Non-Goals

- Do not promise unsupervised replacement of an experienced engineering team.
  This workflow should amplify the team, not hide risk behind confident output.
- Do not treat OpenAPI as the whole truth. OpenAPI describes HTTP interface
  shape well, but service migrations also need domain context, persistence
  behavior, side effects, queues, integrations, operational guarantees, rollout
  plans, and consumer-specific compatibility notes.
- Do not generate a Phoenix codebase before the old service's contract is
  sufficiently scoped. Premature codegen creates polished wrong code.
- Do not let migration-specific extractors become permanent RunicAI product
  abstractions too early. Prefer data-driven workflow blueprints and reusable
  generic components. Extract stable components only after repeated pressure.

## Target User

The primary user is an experienced engineer or software contractor leading a
high-risk service migration. They understand the source system enough to judge
facts, approve tradeoffs, and review PRs, but they want RunicAI to perform the
heavy, repetitive work:

- inventory the API boundary;
- inspect code paths and dataflow;
- generate evidence-linked docs;
- produce an OpenAPI contract;
- create Phoenix implementation slices;
- write Phoenix conn tests and integration probes;
- diff old/new HTTP behavior;
- maintain a migration backlog;
- manage parallel worktrees and agent runs;
- package PRs for human review;
- feed review feedback into future runs.

## Project Shape

A typical project has at least three running surfaces:

1. The old service, either local, staging, or production shadow access.
2. The new Phoenix service, initially local or staging.
3. A proxy, load balancer, gateway, or service mesh that can route selected
   paths from old to new and back.

The workflow should assume route-by-route or resource-by-resource migration.
The cutover unit may be:

- one HTTP method and path;
- one resource family;
- one bounded domain context;
- one frontend-consumed flow;
- one idempotent read path before write paths;
- one internal-only endpoint before external public routes.

The cutover unit is a configurable project decision, not a fixed RunicAI
assumption.

## Stage 0: Migration Intake

Before RunicAI can run a useful migration workflow, it needs a structured
project profile. This should be a multi-step LiveView form backed by a durable
`MigrationProject` record, with the ability to save drafts and attach evidence
later.

### Intake Inputs

Project identity:

- migration name;
- old service repo path and primary language/framework;
- target Phoenix repo path or desired new project path;
- owner/team;
- expected project phase: discovery, spike, first slice, parallel migration,
  rollout, or maintenance.

Source access:

- old service repository path;
- optional frontend repository paths;
- documentation paths;
- existing OpenAPI/Swagger/Postman/Insomnia/API Blueprint artifacts;
- issue tracker or project notes if available;
- database schema dumps or migrations;
- logs/traces if available and approved.

Runtime access:

- old service base URL(s);
- new Phoenix base URL(s);
- local commands for old service boot;
- local commands for new service boot;
- test commands;
- health-check routes;
- auth credentials or secret references;
  - how to get tokens/refresh/ add or remove scopes and authorization constraints
- network policy and allowed domains;
- whether state-changing probes are allowed.

Data access:

- database connection shape;
- snapshot/backfill strategy;
- sanitized fixture strategy;
- PII constraints;
- seed data commands;
- whether old and new services can point at equivalent datasets;
- whether dual-write, replay, or synthetic fixture generation is allowed.

Contract policy:

- compatibility strictness by status code, headers, body, pagination, ordering,
  null handling, time formats, float precision, string/number coercion,
  enum casing, error shape, and default values;
- ignored fields such as timestamps, request ids, trace ids, signatures, and
  nondeterministic ordering;
- tolerances for eventually consistent side effects;
- required negative cases and auth failures.

Target Phoenix preferences:

- Phoenix version and generation style;
- JSON library conventions (built-in JSON module, maybe Jason);
- context boundaries;
- naming conventions;
- Ecto schema preferences;
- auth/plug strategy;
- telemetry/logging conventions;
- whether to preserve legacy route names or move toward Phoenix idioms behind
  the same external contract.
- DB migrations, Postgres/or other db configuration

Rollout infrastructure:

- proxy/load balancer type: NGINX, HAProxy, Envoy, AWS ALB, API Gateway,
  Kubernetes ingress, service mesh, custom router, or unknown;
- route matching granularity;
- header/cookie/canary support;
- shadow traffic support;
- rollback mechanism;
- environment promotion path.

Agent budget and policy:

- Model(s), API keys, providers, etc
- max concurrent worktrees;
- max agent concurrency;
- max LLM cost;
- allowed toolsets;
- write policy;
- command approval policy;
- PR branch naming;
- Github/git repos/git credentials
- human review gates.

### Intake Output

The intake stage should create a durable configuration artifact, for example:

```elixir
%RunicAI.Migration.ProjectProfile{
  id: "migration:billing-api",
  old_service: %{repo: "...", framework: :rails, base_url: "..."},
  target_service: %{repo: "...", framework: :phoenix, base_url: "..."},
  contract_policy: %{json_body: :strict, ignored_fields: ["request_id"]},
  data_policy: %{fixture_strategy: :sanitized_snapshot},
  rollout: %{proxy: :nginx, cutover_unit: :route},
  agent_policy: %{max_worktrees: 6, approval: :ask}
}
```

This profile becomes run context for every generated workflow. The model can
choose tasks, but the project profile constrains what it may touch.

## Stage 1: Grounded Scope Of Work

Stage 1 answers: "What are we migrating, how does it behave, how risky is it,
and how can we verify progress incrementally?"

This stage should produce durable, evidence-linked artifacts before any serious
Phoenix generation begins.

### Stage 1 Deliverables

Required deliverables:

- `openapi.json` or an encodable Elixir map/struct representation of the HTTP
  API contract.
- API boundary inventory: all routes, methods, params, request bodies,
  response statuses, headers, content types, auth requirements, and examples.
- Domain context map: resources, aggregates, commands, queries, invariants,
  persistence models, cross-domain calls, and ownership guesses.
- Endpoint dataflow notes: controller/action path, serializers/views,
  validations, queries, transactions, emitted events, background jobs,
  external API calls, caches, and failure behavior.
- Schema catalog: request/response schemas, database tables, enums, embedded
  shapes, polymorphic shapes, pagination wrappers, and error envelopes.
- Side-effect catalog: writes, emails, queue messages, webhooks, audit logs,
  cache invalidations, metrics, notifications, and third-party calls.
- Test coverage map: existing tests by route/domain, missing coverage, useful
  fixtures, factory data, and high-confidence golden cases.
- Consumer map: frontend/API clients consuming each route, payload fields used,
  assumptions observed in client code, and compatibility risks.
- Migration backlog: endpoint/resource slices with estimated complexity,
  dependencies, confidence, unknowns, and suggested cutover order.
- Verification plan: how to prove each slice through Phoenix conn tests,
  old/new Req probes, diff policies, fixture data, and rollout checks.

Optional deliverables:

- OpenAPI extension fields such as `x-runic-ai-evidence`,
  `x-runic-ai-side-effects`, `x-runic-ai-risk`, `x-runic-ai-consumers`, and
  `x-runic-ai-fixtures`.
- Mermaid diagrams for endpoint dataflow and domain dependencies.
- Proxy route inventory and a draft cutover matrix.
- A "known unknowns" report for operator review.
- Liveview Kanban view of route migration progress

### Stage 1 Workflow Decomposition

The root workflow should not be a single long prompt. It should be a
coordinator-generated Runic workflow that launches bounded sub-workflows, each
with explicit artifacts and scorecards. It should be fault tolerant if a generated sub-workflow fails in some way the coordinator can observe, orient, act and decide to remediate and continue onward towards its goal.

Candidate sub-workflows:

| Workflow | Goal | Primary output |
| --- | --- | --- |
| `repo_inventory` | Identify frameworks, entrypoints, route files, serializers, models, tests, jobs, config, and docs. | Source inventory with evidence refs. |
| `route_inventory` | Extract route table and map paths to handlers. | Route catalog. |
| `openapi_reconciliation` | Compare existing spec, if any, with code and runtime observations. | Spec gap report. |
| `endpoint_dataflow` | Trace each route from handler through persistence, side effects, and response rendering. | Per-endpoint dataflow docs. |
| `schema_extraction` | Infer request/response schemas from code, serializers, fixtures, tests, and runtime samples. | Schema catalog and OpenAPI components. |
| `domain_context` | Group endpoints into domain contexts and business workflows. | Domain map. |
| `auth_policy` | Discover authn/authz/session/tenant/rate-limit behavior. | Security contract notes. |
| `side_effects` | Locate jobs, queues, external calls, emitted events, caches, and transactions. | Side-effect catalog. |
| `test_coverage` | Map existing tests to API behavior and identify missing golden cases. | Coverage and fixture plan. |
| `consumer_analysis` | Inspect frontend/client repos for actual route and field usage. | Consumer dependency map. |
| `runtime_sampling` | Use allowed HTTP probes against the old service to capture representative responses. | Golden request/response examples. |
| `migration_backlog` | Turn scope into sequenced slices with risk and dependencies. | Migration backlog. |

Each sub-workflow should emit `EvidenceRecord`s, not just prose. A fact without
source references should be treated as a hypothesis until verified.

### Evidence Model

Stage 1 needs a first-class evidence graph so later agents can retrieve facts
without rereading the whole old repo.

```elixir
%RunicAI.Migration.EvidenceRecord{
  id: "evidence:route:GET:/api/orders/:id",
  kind: :route,
  claim: "GET /api/orders/:id renders OrderSerializer with line_items",
  confidence: :high,
  sources: [
    %{type: :file_range, path: "config/routes.rb", lines: [42, 42]},
    %{type: :file_range, path: "app/controllers/orders_controller.rb", lines: [12, 27]},
    %{type: :runtime_sample, probe_id: "probe:old:orders-show:happy-path"}
  ],
  produced_by: "workflow:stage1:endpoint_dataflow",
  verified_at: ~U[2026-05-15 00:00:00Z]
}
```

The evidence graph should support:

- source refs to files, line ranges, routes, tests, runtime probes, SQL
  snapshots, logs, and external docs;
- confidence levels and unresolved disagreements;
- relation edges such as `route_uses_serializer`, `handler_writes_table`,
  `route_enqueues_job`, `frontend_reads_field`, and `slice_depends_on`;
- fact promotion after human review;
- invalidation when source files change.

### OpenAPI Role

OpenAPI should be the root HTTP contract artifact because it is language
agnostic and can feed documentation, client generation, server scaffolding, and
testing. For this use case, OpenAPI is necessary but not sufficient.

RunicAI should assemble OpenAPI from multiple sources:

- existing spec artifacts;
- route declarations;
- controller/action code;
- serializers/views;
- request validators;
- model/schema declarations;
- tests and factories;
- runtime probes;
- frontend client observations;
- human corrections.

The generated OpenAPI should be versioned and scorecarded:

- every path operation has at least one evidence source;
- every request body and response schema has provenance;
- every required field is justified by code, tests, runtime samples, or human
  review;
- every auth/security requirement is explicit;
- every undocumented side effect is captured in RunicAI extension metadata or
  adjacent docs;
- unresolved ambiguity is visible rather than hidden.

## Stage 2: Verified Phoenix Vertical Slice

Stage 2 answers: "Can RunicAI migrate one endpoint or resource slice all the
way to a reviewable Phoenix PR with evidence that the old and new contracts
match?"

This is the most important product milestone. A single successful slice proves
that the discovery artifacts are useful and the generated workflow can close
the loop from spec to code to tests to diffing to review.

It may be required to have the existing Phoenix project generated or to generate one based on user specs. See: https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html

### Slice Selection

The first slice should usually be:

- low or medium side-effect risk;
- high enough value to exercise real conventions;
- covered by existing tests or easy runtime probes;
- backed by manageable fixture data;
- not blocked by too many shared abstractions;
- representative of response shape, auth, pagination, and domain modeling.

Good first candidates:

- read-only `GET /resource/:id`;
- indexed list with pagination and filters;
- internal status/config endpoint;
- a simple create/update command with isolated side effects.

Poor first candidates:

- a high-volume payment path;
- a deeply coupled multi-step workflow;
- a route with nondeterministic third-party dependencies;
- a route whose behavior is not understood by the team.

### Stage 2 Workflow

```text
select slice
  -> retrieve Stage 1 facts and OpenAPI operation
  -> produce Phoenix implementation plan
  -> generate or update router/controller/context/schema code
  -> generate fixtures/backfill data
  -> generate Phoenix conn tests from the contract
  -> boot old and new services
  -> run old/new Req probes
  -> canonicalize and deep-diff responses
  -> repair generated code or tests
  -> run project verification commands
  -> package a PR with evidence, risks, and cutover notes
```

### Required Slice Artifacts

For each migrated slice, RunicAI should produce:

- implementation plan with linked Stage 1 evidence;
- changed file list;
- Phoenix route/controller/context/Ecto code;
- Phoenix conn tests asserting JSON request/response behavior;
- fixture/backfill instructions or generated fixture data;
- Req-based old/new integration probe definitions;
- diff report with raw and canonicalized responses;
- unresolved compatibility notes;
- code quality checklist;
- PR summary;
- rollback/cutover note for the proxy/load balancer.

### Contract Diffing

The diffing layer should be explicit and configurable. It should compare:

- status code;
- response headers that matter;
- content type;
- JSON body shape;
- field names;
- field types;
- null versus absent fields;
- numeric precision and string/numeric mismatches or data type differences;
- arrays and ordering;
- pagination metadata;
- error envelopes;
- auth failures;
- validation errors;
- side-effect observations where feasible.

Canonicalization policies should be visible:

```elixir
%RunicAI.Migration.DiffPolicy{
  ignore_paths: ["$.meta.request_id", "$.data[*].updated_at"],
  unordered_paths: ["$.data[*].relationships.tags"],
  numeric_tolerances: %{"$.data[*].amount" => Decimal.new("0.01")},
  type_coercions: %{"$.data[*].id" => [:integer, :string]},
  require_headers: ["content-type"],
  forbid_extra_fields?: false
}
```

A passing diff under a loose policy should not be displayed the same as a
passing diff under a strict policy. The scorecard should include the policy
strictness.

### Done For One Slice

A slice is done when:

- the Phoenix implementation passes compile/format/test checks;
- Phoenix conn tests cover happy path, important failure paths, auth behavior,
  and representative request shapes;
- Req probes pass against old and new services using equivalent data;
- diff reports are accepted by policy or explicitly waived by a human;
- side effects are either preserved, mocked, intentionally deferred, or called
  out as blockers;
- the PR contains enough context for a reviewer to understand evidence and
  risk;
- the cutover note says how to route traffic to the new endpoint and how to
  roll it back.

## Stage 3: Parallel Migration Program

Once the first slice succeeds, RunicAI can run a migration program. This is
where worktrees, parallel agents, shared facts, and human review queues matter.

### Worktree Model

Each active slice should run in an isolated worktree:

```text
main target repo
  worktree/migration-orders-show
  worktree/migration-orders-index
  worktree/migration-customers-create
```

The coordinator should track:

- slice assignment;
- branch name;
- worktree path;
- base commit;
- known shared dependencies;
- generated code conventions;
- test status;
- diff status;
- PR status;
- review feedback;
- merge/cutover status.

Agents should not independently invent conflicting shared abstractions. The
coordinator should serialize or explicitly review changes to shared modules,
contexts, plugs, schemas, test helpers, and fixture helpers.

### Feedback Into Knowledge Base

Every accepted PR should produce durable facts:

- chosen Phoenix context/module names;
- reusable serializers or view helpers;
- fixture patterns;
- route-specific diff policies;
- known legacy quirks;
- accepted intentional behavior changes;
- reviewer preferences;
- test helper conventions;
- what was tested at what layer (context layer (data and behavior), phoenix layer (web surface), integration / manual / smoke test)
- proxy/cutover notes.

Future agents should retrieve these facts before planning new slices. This is
the difference between a fleet that gets faster and a fleet that repeats the
same mistakes in parallel.

### Human Review Loop

PR review is part of the workflow, not an afterthought.

RunicAI should ingest:

- review comments;
- CI failures;
- reviewer-requested changes;
- rejected assumptions;
- approved waivers;
- merged PR outcomes.

Then it should:

- repair the current slice;
- update the migration knowledge base when the feedback is generalizable;
- mark facts as superseded when review disproves them;
- adjust future planning and scorecards.

## Stage 4: Cutover And Operations

Migration does not end when a PR merges. The system should help operators move
traffic safely.

Cutover artifacts:

- proxy/load-balancer route rule proposal;
- environment promotion checklist;
- shadow traffic plan if supported;
- canary percentage or header-based routing plan;
- rollback command/config note;
- expected telemetry and logs;
- smoke probe list;
- incident escalation note.

RunicAI does not need to own every cloud API immediately. The first version can
generate provider-specific plans and reviewable config diffs. Later versions
can add tool-backed integrations for common environments.

## Frontend Consumer Analysis

If a React, Vue, mobile, or other client repo consumes the old API, RunicAI
could run a parallel Stage 1 workflow over that client.

The goal is not to rewrite the frontend. The goal is to discover:

- which endpoints are actually used;
- which fields are read, written, transformed, or compared;
- whether the client assumes string ids, numeric strings, enum casing, nulls,
  ordering, pagination details, or error message text;
- whether the client has mocks or generated API clients;
- which flows exercise each endpoint;
- which frontend tests or Playwright scenarios can verify compatibility.
- what kind of breaking changes are possible
- if new endpoints to replace old problematic ones (return too much data, n+1, authorization issues, poor restful design, etc)

This consumer map should feed:

- OpenAPI schema confidence;
- route prioritization;
- diff strictness;
- negative test cases;
- cutover validation.

## RunicAI Workflow Architecture

The root migration workflow should be a long-lived durable workflow, not a
single terminal command. It should compile into Runic-owned graphs and execute
through existing RunicAI runtime, persistence, scorecard, and repair surfaces. This should give us a durable execution basis with causal tracing and monitoring to debug, fix, and repair itself at runtime or recover from restarts and continue.

### Root Coordinator

```text
MigrationProjectProfile
  -> IntakeValidator
  -> SourceDiscovery
  -> ProjectDecomposer
  -> StageWorkflowPlanner
  -> ParallelSubworkflowLauncher
  -> EvidenceGraphReducer
  -> OpenAPIAssembler
  -> MigrationBacklogPlanner
  -> OperatorReviewGate
  -> SlicePlanner
  -> CodingAgentFleet
  -> ContractProbeRunner
  -> Scorecard
  -> PRPackager
  -> CutoverPlanner
```

The coordinator should use generated workflow blueprints as data. For example,
Rails, Django, Express, Laravel, Spring, and legacy in-house frameworks may
need different route extraction and dataflow tracing steps. RunicAI should not
hard-code every framework path into one static workflow.

### RALPH-Style Slice Loop

For this use case, a practical RALPH profile could mean:

- Recon: gather route, schema, domain, fixture, and runtime evidence.
- Analyze: identify invariants, dependencies, side effects, risk, and unknowns.
- Lay out: produce a small implementation and verification plan.
- Produce: generate Phoenix code, tests, probes, fixtures, and docs.
- Harden: run verification, diff, repair, scorecard, and prepare review.

The exact acronym is less important than making it a named, inspectable loop
policy. The workbench should show which phase a slice is in and what evidence
or error is blocking the next phase.

### Reusable Runtime Records

Candidate records:

```elixir
%RunicAI.Migration.EndpointContract{}
%RunicAI.Migration.DomainContext{}
%RunicAI.Migration.SchemaCatalog{}
%RunicAI.Migration.SideEffect{}
%RunicAI.Migration.ConsumerUse{}
%RunicAI.Migration.MigrationSlice{}
%RunicAI.Migration.ContractProbe{}
%RunicAI.Migration.DiffReport{}
%RunicAI.Migration.CutoverPlan{}
%RunicAI.Migration.KnowledgeFact{}
```

These records should be serializable to JSON and persisted as artifacts/facts.
They do not all need database tables in the first version. Start with artifact
rows and workflow facts; promote to typed schemas when query pressure proves
the need.

## New Components RunicAI Would Need

RunicAI already has useful generic substrate: source discovery, source
splitting/materialization, LLM map, record map/group, document compare,
hierarchical reduce, report composer, artifact writer, objective scorecard,
budget ledger, workflow blueprint validation, repair, SQLite persistence, and
the workbench event/read-model surface.

The migration product needs additional components. Some can start as generated
workflow policies over existing tools; others deserve first-class modules once
the pattern stabilizes.

### Discovery Components

- `FrameworkDetector`: detects Rails, Django, Express, Laravel, Spring, Phoenix,
  or custom route/config conventions.
- `RouteInventory`: extracts method/path/handler metadata from framework route
  declarations and runtime route listings.
- `HandlerLocator`: maps routes to controllers/actions/functions/middleware.
- `SerializerInventory`: discovers JSON serializers, views, encoders, response
  builders, and error envelope code.
- `ModelInventory`: discovers persistence models, migrations, schema files,
  enums, validations, and associations.
- `TestInventory`: maps test files to endpoints, fixtures, factories, and
  behavior assertions.
- `ConsumerInventory`: scans frontend/client repos for HTTP calls, generated
  clients, GraphQL/REST adapters, mocks, and field usage.

### Analysis Components

- `EndpointDataflowTracer`: builds route-to-response dataflow with evidence.
- `CommandQueryClassifier`: separates read paths, command paths, and workflows.
- `SideEffectCataloger`: catalogs jobs, queues, emails, webhooks, cache writes,
  external calls, audit logs, events, and transactions.
- `AuthPolicyExtractor`: discovers authentication, authorization, tenancy,
  rate-limit, and feature-flag behavior.
- `SchemaInferencer`: merges code/test/runtime observations into request and
  response schemas.
- `DomainContextMapper`: groups endpoints into bounded contexts and flags
  ambiguous ownership.
- `RiskClassifier`: scores routes by complexity, statefulness, coupling,
  coverage, side effects, consumer sensitivity, and data availability.

### Contract Components

- `OpenAPIAssembler`: emits OpenAPI JSON/YAML/Elixir data from endpoint
  contracts and schema catalog entries.
- `OpenAPILinter`: validates completeness and consistency of generated specs.
- `SpecReconciler`: compares existing maintained specs with code/runtime facts.
- `ContractExampleGenerator`: proposes request/response examples and marks
  whether they came from runtime, tests, fixtures, or synthesis.
- `ContractProbePlanner`: chooses representative HTTP probes per endpoint.
- `ReqContractProbe`: runs old/new service probes with Req and stores results.
- `ResponseCanonicalizer`: applies diff policy before comparison.
- `DeepJSONDiff`: reports shape/type/value differences with JSONPath refs.
- `CompatibilityScorecard`: grades a slice's old/new behavioral match.

### Phoenix Migration Components

- `PhoenixProjectPlanner`: chooses project/module/context layout for the target.
- `PhoenixSlicePlanner`: converts endpoint contracts and domain facts into a
  small implementation plan.
- `PhoenixRouterSynthesizer`: writes or patches router routes.
- `PhoenixControllerSynthesizer`: writes controllers/actions and error handling.
- `PhoenixContextSynthesizer`: writes domain context functions.
- `EctoSchemaMapper`: maps legacy models/tables to Ecto schemas and queries.
- `ConnTestGenerator`: generates Phoenix conn tests from OpenAPI examples,
  runtime samples, and diff cases.
- `FixtureBackfillPlanner`: creates or documents data needed for tests/probes.
- `LegacyQuirkAdapter`: isolates compatibility quirks when the external
  contract must preserve odd legacy behavior.

These Phoenix components should probably be coding-agent capabilities, not
always pure RLM components. The workflow plans and verifies the slice; the
coding agent performs file edits under workspace policy.

### Program Orchestration Components

- `WorktreeManager`: creates, tracks, and cleans isolated worktrees.
- `SliceAssignmentPlanner`: chooses slices for parallel work based on risk,
  dependencies, and shared-code conflicts.
- `AgentFleetCoordinator`: launches bounded child sessions and aggregates
  results.
- `SharedAbstractionGate`: blocks or reviews changes to shared target modules.
- `PRPackager`: produces branch summaries, evidence links, diff reports, and
  reviewer notes.
- `ReviewFeedbackIngestor`: turns PR comments and CI failures into repair tasks
  or promoted knowledge facts.
- `KnowledgeFactPromoter`: proposes durable facts for operator approval.
- `CutoverPlanner`: emits route-level proxy/load-balancer rollout plans.

### Safety And Policy Components

- `StateChangingProbeGuard`: prevents accidental destructive HTTP probes.
- `SecretRedactor`: scrubs credentials from artifacts, traces, and diffs.
- `PIIPolicyGate`: ensures fixture/runtime samples obey project data policy.
- `ExternalIntegrationMockPlanner`: decides when to mock, record, replay, or
  call third-party services.
- `CostBudgetLedger`: extends the existing budget ledger with migration-project
  dimensions.
- `MigrationFailureClassifier`: classifies failures as environment, evidence,
  spec, codegen, data, diff, policy, or review blockers.

## Workbench UI Needs

The LiveView workbench should become the operator console for the migration.
The first useful UI does not need to be a giant enterprise dashboard, but it
does need to make long-running work inspectable and steerable.

### Project Setup Wizard

Screens:

- project identity and repos;
- old/new runtime commands and URLs;
- data and fixture policy;
- existing spec/docs upload or path entry;
- frontend/client repos;
- target Phoenix preferences;
- rollout/proxy environment;
- agent budget and approval policy;
- initial discovery run confirmation.

The wizard should validate inputs incrementally and show "ready to run" status
per section.

Defaults should follow Phoenix conventions such as generated by https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Json.html and other mix tasks and modified typically - avoiding CRUD if possible and focusing on domain driven modeling, command query separation and having clean context boundaries where Phoenix isn't the app but a consumer of the domain context responsible for web concerns only.

### Migration Dashboard

Panels:

- project health;
- current stage;
- route inventory progress;
- OpenAPI completeness;
- endpoint backlog by domain/risk/status;
- active worktrees and agents;
- pending review gates;
- latest diff failures;
- cost/runtime budget;
- recent promoted knowledge facts.

Kanban View of progress migrating so a user can see what's ready for review, in-progress, queued, planning, complete and so on.

This page should be dense and operational, not a marketing-style summary.

### Route And Slice Explorer

For each route/slice:

- OpenAPI operation view;
- evidence graph;
- dataflow diagram;
- domain context;
- side effects;
- tests/fixtures;
- frontend consumers;
- old/new probe examples;
- diff history;
- implementation status;
- PR status;
- cutover readiness.

### Spec Studio

The operator needs to review generated OpenAPI changes:

- path/method tree;
- schema browser;
- example browser;
- unresolved ambiguity list;
- spec version history;
- existing spec reconciliation;
- approval controls for generated operations and schemas.

### Diff Explorer

Diff reports need a purpose-built surface:

- raw old/new request and response;
- canonicalized old/new response;
- JSONPath diff list;
- ignored differences;
- policy strictness;
- classification: breaking, tolerated, waived, unknown;
- buttons to accept waiver, tighten policy, repair code, repair fixture, or
  update spec.

### Agent Fleet View

For parallel migration:

- worktree cards;
- assigned slice;
- current RALPH phase;
- last event;
- blocked reason;
- changed files;
- test/diff status;
- review requests;
- PR link/status.

### Knowledge Base Review

The UI should let humans approve facts that future agents will rely on:

- proposed fact;
- evidence;
- confidence;
- scope: project, domain, route, target Phoenix repo, reviewer preference;
- expiration/invalidation condition;
- approve/reject/edit controls.

## Error Surfaces

Migration workflows will fail often. The product should make failures useful.

### Common Failure Classes

Environment:

- old service cannot boot;
- new service cannot boot;
- missing dependency;
- database unavailable;
- migrations fail;
- credentials missing;
- local port conflict;
- network blocked.

Discovery:

- route table cannot be found;
- dynamic routes are generated at runtime;
- framework convention is custom;
- serializers are implicit;
- handler path is ambiguous;
- source evidence conflicts with runtime behavior.

Contract:

- existing OpenAPI is stale;
- runtime response violates inferred schema;
- field type differs by fixture;
- error shape is inconsistent;
- auth behavior is tenant or role dependent;
- response is nondeterministic.

Data:

- fixture cannot reproduce old behavior;
- required data contains PII;
- old and new datasets are not equivalent;
- database side effects leak between probes;
- timestamps, ids, or counters make diffs noisy.

Code generation:

- Phoenix code does not compile;
- generated Ecto query is semantically wrong;
- context boundary conflicts with existing target conventions;
- shared helper changes collide with another worktree;
- generated compatibility shim is too broad.

Verification:

- conn tests fail;
- old/new Req diff fails;
- external integration unavailable;
- side effect cannot be safely probed;
- test suite is flaky;
- generated code passes tests but scorecard lacks evidence.

Program:

- agent exceeds budget;
- worktree is stale;
- branch conflicts with merged slice;
- PR review rejects a general assumption;
- knowledge base fact is invalidated;
- cutover config cannot express desired route granularity.

### Diagnostic Shape

Failures should be normalized:

```elixir
%RunicAI.Migration.Diagnostic{
  class: :contract,
  severity: :blocking,
  title: "Runtime sample disagrees with inferred response schema",
  evidence: ["probe:old:orders-show:case-3", "schema:OrderResponse"],
  suggested_actions: [
    %{label: "Update schema", action: :repair_spec},
    %{label: "Add fixture case", action: :generate_fixture},
    %{label: "Ask operator", action: :review}
  ],
  retryable?: true,
  safe_to_repair?: true
}
```

The workbench should show:

- what failed;
- why it matters;
- exact evidence;
- suggested next actions;
- whether the agent can repair it automatically;
- whether human approval is needed;
- what future work is blocked.

## Scorecards

Objective scorecards should be specialized for migration stages.

### Stage 1 Scope Scorecard

Checks:

- route inventory coverage;
- OpenAPI operation coverage;
- schema provenance coverage;
- dataflow evidence coverage;
- side-effect coverage;
- auth/security coverage;
- consumer analysis coverage;
- unresolved ambiguity count;
- high-risk route count;
- migration backlog completeness.

### Slice Readiness Scorecard

Checks:

- selected slice has enough evidence;
- target implementation plan references facts;
- fixture strategy is available;
- diff policy is explicit;
- side effects are understood;
- reviewer risk is acceptable.

### Implementation Scorecard

Checks:

- code compiles/formats/tests;
- Phoenix conn tests cover required cases;
- generated code follows target conventions;
- no broad compatibility shims without review;
- shared abstractions are minimal and justified;
- changed files match slice ownership.

### Compatibility Scorecard

Checks:

- old/new probes pass;
- diffs are empty or accepted under policy;
- strictness level is visible;
- auth and failure cases match;
- side effects are preserved, deferred, mocked, or blocked with rationale.

### PR Review Scorecard

Checks:

- PR summary includes evidence and diff report;
- reviewer questions are answered;
- general feedback has been promoted to knowledge facts or explicitly scoped to
  one slice;
- unresolved risks are labeled.

## Productization By A Contractor

An experienced software contractor could package this as a repeatable migration
program with RunicAI as the project engine.

### Discovery Engagement

Deliverables:

- migration profile;
- API/domain/side-effect inventory;
- OpenAPI spec;
- risk matrix;
- migration backlog;
- first-slice recommendation;
- estimate ranges by route/domain/risk class;
- staffing and review plan.

This is valuable even before any rewrite begins.

### First-Slice Engagement

Deliverables:

- one Phoenix vertical slice;
- conn tests;
- Req diff probes;
- fixture/backfill strategy;
- reviewable PR;
- cutover plan;
- lessons learned and knowledge base updates.

This proves whether the project is automation-friendly.

### Migration Factory Engagement

Deliverables:

- parallel worktree/agent operation;
- weekly route completion reports;
- PR queue;
- contract diff dashboard;
- reviewed knowledge base;
- cutover batches;
- human escalation handling;
- final decommission checklist.

The contractor's expertise is still central. They tune the workflow, judge
risk, handle politics and architecture tradeoffs, and decide when compatibility
should preserve legacy behavior versus when the business should accept a
versioned change.

### Commercial Positioning

This can be sold as:

- "API migration discovery and contract extraction";
- "verified Phoenix rewrite accelerator";
- "route-by-route migration factory";
- "AI-assisted legacy service strangler workflow";
- "contract-backed API modernization with human review."

The strongest promise is reduced discovery and implementation labor with better
evidence trails, not magic elimination of engineering judgment.

## Open Source Dogfood Corpus

Web research on 2026-05-17 found several open source, decently large JSON API
services that are good candidates for dogfooding this migration factory. The
best corpus should deliberately mix frameworks, API styles, documentation
quality, runtime difficulty, and side-effect profiles.

The goal is not to migrate these projects for real. The goal is to use them as
repeatable smoke and integration fixtures for RunicAI's migration workflows:

- Can RunicAI identify framework, route declarations, handlers, serializers,
  auth, persistence, tests, docs, and existing OpenAPI artifacts?
- Can it choose a safe route slice and produce evidence-linked endpoint
  contracts?
- Can it run read-only probes against a local service and compare them to
  generated OpenAPI examples?
- Can it generate a Phoenix slice, conn tests, Req probes, and a compatibility
  report for a representative endpoint family?
- Can it explain why a candidate is blocked when the runtime is too heavy,
  auth is unavailable, fixtures are missing, or side effects are unsafe?

### Candidate Repositories

Snapshot values below are current as of the 2026-05-17 research pass.

| Framework | Candidate | Why it is useful | Approx size / signal | Suggested use |
| --- | --- | --- | --- | --- |
| Rails | [Discourse](https://github.com/discourse/discourse) plus [discourse_api_docs](https://github.com/discourse/discourse_api_docs) | Large Rails codebase with API docs generated from rswag specs in the core repo's `spec/requests/api` directory, plus committed `openapi.yml` / `openapi.json` docs artifacts. | About 47k GitHub stars on the app; API docs repo states the OpenAPI files are generated from Discourse request specs. | Best Rails first target for contract reconciliation: extract routes/specs from source, compare to generated OpenAPI, then migrate one read-only API endpoint. |
| Rails | [Mastodon](https://github.com/mastodon/mastodon) | Real Rails JSON API with OAuth2, REST and streaming APIs, PostgreSQL, Redis, Sidekiq, and a broad public client ecosystem. The repo README says Ruby on Rails powers the REST API. | About 50k stars. | Heavier Rails stress target after Discourse: auth, pagination, timeline/account/status resources, queue/cache side effects, and ActivityPub-adjacent domain complexity. |
| Django / DRF | [NetBox](https://github.com/netbox-community/netbox) | Strong first Django target. NetBox documents a DRF-powered JSON REST API, interactive OpenAPI docs at `/api/schema/swagger-ui/`, a clear `/api/` hierarchy, token auth, filtering, ordering, pagination, and many CRUD resources. | About 20.5k stars; Apache-2.0. | Best overall first dogfood project: bootable local app, explicit API docs, predictable resources, and enough complexity to exercise schema extraction and diff policies. |
| Django / DRF | [AWX](https://github.com/ansible/awx) | Large production-style Django/DRF API plus task engine. The repo describes itself as a web UI, REST API, and task engine built on Ansible, with Django and Django REST Framework topics. | About 15.4k stars. | Django heavyweight stress target: use when we want RBAC, background jobs, task state, operational resources, and runtime boot complexity. |
| Django | [Zulip](https://github.com/zulip/zulip) | Large Django application with a substantial REST API that powers Zulip's web and mobile apps, documented error conventions, API keys, bindings, and many message/organization operations. | About 25.2k stars. | Good client-consumer and auth/error-shape target, especially for testing whether generated contracts match public API docs and server source. |
| FastAPI | [Prefect](https://github.com/PrefectHQ/prefect) | Prefect's server docs expose a `create_api_app` path that creates a FastAPI app serving the Prefect REST API. The domain has workflows, deployments, runs, state, and orchestration semantics. | About 22.4k stars; Apache-2.0. | Best FastAPI first target for RunicAI itself: workflow/run domain vocabulary is familiar, and the API surface naturally tests stateful resources and compatibility diffs. |
| FastAPI | [Polar](https://github.com/polarsource/polar) | Open source monetization/payments platform with a `server` directory, public API, FastAPI/Pydantic/SQLAlchemy/Uvicorn stack references, and API/SDK docs. | About 9.8k stars; Apache-2.0. | Good FastAPI SaaS/product target after Prefect: auth, subscriptions, checkout, webhooks, external integrations, and side-effect policy gates. |
| FastAPI | [OpenBB](https://github.com/OpenBB-finance/OpenBB) | Large Python financial data platform that can launch a FastAPI/Uvicorn server on localhost and exposes REST APIs for downstream applications. | About 67.7k stars; AGPLv3. | Excellent API-scale and OpenAPI-volume target, but not first: many routes depend on external market-data providers and API-key/data freshness policy. |

### Recommended Benchmark Ladder

Use a ladder instead of one trophy repo:

1. `netbox-readonly-smoke`: clone/boot NetBox with seed data, ingest its
   `/api/schema/swagger-ui/` or schema endpoint, independently inventory
   `/api/dcim/sites/`, `/api/dcim/devices/`, and `/api/ipam/prefixes/`, then
   migrate one read-only list/detail pair into Phoenix.
2. `discourse-openapi-reconciliation`: inspect Discourse routes and
   `spec/requests/api`, compare RunicAI's extracted operation set to the
   generated Discourse API docs repo, then migrate one safe topic/category read
   endpoint.
3. `prefect-fastapi-stateful-slice`: run a local Prefect server, inventory the
   FastAPI routers and generated OpenAPI, then migrate a read-only flow or
   deployment endpoint while preserving nested state/resource shapes.
4. `zulip-client-contract-smoke`: use Zulip's API docs plus server source to
   verify auth, documented error envelopes, and one message-read endpoint. This
   is useful once `consumer_analysis` exists because the API powers real web
   and mobile clients.
5. `awx-operational-api-stress`: after the simpler DRF path works, use AWX to
   test task-engine side effects, RBAC, operational status, and route classes
   that are not safe to probe with writes.
6. `mastodon-federated-rails-stress`: use Mastodon to test large Rails API
   discovery, OAuth scope handling, queues/caches, and public API compatibility
   with a broad third-party client ecosystem.
7. `openbb-large-openapi-stress`: use OpenBB to test very large FastAPI
   OpenAPI surfaces and endpoint grouping, but gate runtime probes behind
   provider-key and data-freshness policies.

### First Dogfood Scenario

The first practical dogfood scenario should be NetBox, not because it is the
most dramatic, but because it is a clean integration test for the exact product
we want:

```text
Input:
  old service repo: netbox-community/netbox
  old service framework: django_drf
  old service base URL: local NetBox
  target Phoenix repo: generated throwaway Phoenix app
  selected domain: DCIM sites/devices or IPAM prefixes
  selected operations:
    GET /api/dcim/sites/
    GET /api/dcim/sites/{id}/
    GET /api/dcim/devices/?site_id={id}
  state-changing probes: false
  auth: local token or anonymous read-only if configured

Workflow:
  detect Django/DRF and NetBox app layout
  import existing OpenAPI/schema docs as one evidence source
  independently extract urls, routers, viewsets, serializers, models, filters
  sample old service JSON for seeded objects
  assemble endpoint contracts with provenance
  generate Phoenix routes/controllers/context/read models for the selected slice
  generate conn tests from runtime samples and OpenAPI examples
  run old/new Req probes
  canonicalize pagination URLs, ids, timestamps, and ordering where configured
  produce diff report, scorecard, and PR-style migration note

Done:
  route inventory for the selected NetBox domain
  OpenAPI operation subset with `x-runic-ai-evidence`
  Phoenix implementation slice
  Phoenix conn tests
  old/new Req probe definitions and captured responses
  compatibility diff report
  documented blockers for writes/auth/side effects not attempted
```

Why this scenario is strong:

- DRF gives us recognizable routers, serializers, viewsets, permissions,
  filters, pagination, and OpenAPI integration.
- NetBox has many resource families, so a route-by-route backlog is meaningful.
- The first slice can stay read-only and deterministic while still exercising
  nested JSON, related-object serialization, filtering, ordering, pagination,
  auth headers, and schema provenance.
- The workflow can compare three truths: source code, generated/served OpenAPI,
  and runtime samples.
- Failures will be useful product signals: missing seed data, schema/runtime
  mismatch, auth setup, pagination canonicalization, and legacy ID/link
  policies are exactly the kinds of things a real migration factory must make
  visible.

### Smoke Test Matrix

For each corpus candidate, RunicAI should store a repeatable scenario record:

```elixir
%RunicAI.Migration.SmokeScenario{
  id: "netbox-readonly-dcim-sites",
  source_repo: "https://github.com/netbox-community/netbox",
  framework: :django_drf,
  old_service_boot: "docker compose or documented local setup",
  target_repo: "tmp/runic_ai_migration_targets/netbox_phoenix",
  selected_operations: [
    "GET /api/dcim/sites/",
    "GET /api/dcim/sites/{id}/"
  ],
  state_changing_probes?: false,
  required_components: [
    :framework_detector,
    :route_inventory,
    :schema_extraction,
    :openapi_reconciliation,
    :req_contract_probe,
    :deep_json_diff,
    :conn_test_generator
  ],
  expected_artifacts: [
    "route_inventory.json",
    "endpoint_contracts.json",
    "openapi.subset.json",
    "phoenix_slice_plan.md",
    "diff_report.json",
    "scorecard.md"
  ]
}
```

Success criteria across the corpus:

- Stage 1 discovery completes for at least one Rails, one Django/DRF, and one
  FastAPI project.
- Each run produces evidence-linked route inventory and OpenAPI subset artifacts
  without relying solely on the project's existing API docs.
- At least one read-only slice per framework reaches Phoenix code plus conn
  tests plus old/new diff report.
- The workflow classifies blocked state-changing endpoints as policy/data/auth
  blockers instead of silently skipping them.
- The scorecard shows framework-specific extraction gaps that should become
  reusable blueprint improvements.

## Suggested Implementation Path For RunicAI

### Phase 1: Discovery-Only Migration Workflow

Build a workflow profile that reads one old service repo and produces:

- route inventory;
- endpoint docs for a small selected route set;
- draft OpenAPI paths/components;
- evidence records;
- migration backlog.

Use existing RLM components as much as possible. Add only small migration
records and report templates.

### Phase 2: Req Contract Probe And Diff Components

Add:

- `ReqContractProbe`;
- `ResponseCanonicalizer`;
- `DeepJSONDiff`;
- `DiffPolicy`;
- `CompatibilityScorecard`.

This phase can validate existing services before Phoenix generation exists.

### Phase 3: Single Phoenix Slice Generator

Connect the migration workflow to the coding-agent substrate:

- generate a slice plan;
- edit Phoenix router/controller/context/tests;
- run compile/format/test;
- run old/new probes;
- repair once or route to review.

Keep this to one route family before scaling.

### Phase 4: Workbench Migration Project UI

Add the setup wizard, migration dashboard, route explorer, diff explorer, and
knowledge fact review surfaces.

This is when the product becomes operable for long-running projects.

### Phase 5: Worktree And PR Orchestration

Add worktree management, branch tracking, PR packaging, review feedback ingest,
and shared-abstraction gates.

### Phase 6: Cutover Planning Integrations

Start with generated config diffs and checklist artifacts. Add direct provider
tools only after common environments emerge.

## Open Questions

- How much framework-specific discovery should RunicAI ship versus generate as
  workflow blueprints per project?
- Should OpenAPI be stored as a versioned artifact only, or should paths,
  operations, and schemas also become queryable SQLite rows?
- Which target Phoenix conventions should be configurable globally versus
  learned from the target repo?
- How should the workflow represent side effects that cannot be safely probed?
- What is the right default for state-changing old/new probes?
- How should agent-generated fixture data be reviewed for PII risk?
- How should RunicAI arbitrate conflicting facts from code, tests, runtime, and
  humans?
- Should proxy/load-balancer integrations be provider tools or generated
  artifacts reviewed by humans?
- What is the smallest first implementation that proves the migration factory
  without creating too much migration-specific product surface?

## First Practical Scenario

A narrow first scenario could be:

```text
Input:
  old service repo path
  old service base URL
  target Phoenix repo path
  one selected GET endpoint
  one fixture seed command or sample JSON response

Workflow:
  inventory route and handler
  infer response schema
  write one OpenAPI path operation
  generate Phoenix route/controller/context stub
  generate conn test from old response
  run old/new Req probe
  diff response
  repair generated code once
  produce PR-ready report

Done:
  doc artifact
  OpenAPI operation
  Phoenix code and conn test
  diff report
  scorecard
```

That scenario is small enough to build, but it exercises the product's core:
grounded facts, contract extraction, Phoenix generation, verification, repair,
and human review.
