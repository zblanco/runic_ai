# RayOps Vmsan Workflow RLM Integration Report

Status: observed failure

Date: 2026-06-17

## Purpose

This document records a full Workbench integration attempt for the RayOps solar
fulfillment prompt through the browser, Workflow RLM, dynamic workflow planning,
and Vmsan sandbox configuration. The goal was not to tune behavior for RayOps,
but to identify reliability and UX gaps that affect any general-purpose coding
agent task.

## Scenario

Prompt:

```text
Write me a solar fulfillment application using ecto, phoenix, liveview called ray_ops. It should be essentially a multi-tenant business workflow management tool around a “project” entity that houses a fulfillment contract to survey, design, permit, install and then wrap up with inspection/utility interconnection finalization. Research solar fulfillment and design a good data model that is suitable so that this project can have a customer, a customer have potentially many projects, a project can have many designs but one active design allowing for design updates through out the process.
```

Browser launch target:

- URL: `http://localhost:4000/`
- Session: `web-session:HJKFJL9ZJY:A:eb4d10af`
- Run: `rlm:web:HJKFJL9ZKH:B:28268f7a`
- Workspace: `/home/doops/wrk/runic_ai/tmp/rayops-vmsan-integration`
- Agent: `rlm`
- Mode: `patch`
- Approval: `always`
- Sandbox: `vmsan`
- Runtime selection: `elixir`
- Sandbox runtimes: `bash,python,node,elixir,lua`
- Network: `disabled`
- Stateful sandbox: `true`

## Evidence

Chrome DevTools MCP loaded the Workbench successfully. The initial page had
only successful asset requests and Phoenix debug console output. The launch
form submitted this payload through LiveView:

```text
agent=rlm
approve=always
cwd=/home/doops/wrk/runic_ai/tmp/rayops-vmsan-integration
sandbox_backend=vmsan
sandbox_runtime=elixir
sandbox_runtimes=bash,python,node,elixir,lua
sandbox_network=disabled
sandbox_stateful=true
```

The browser navigated to the session page and showed:

```text
SESSION EB4D10AF - RUNNING
rlm - running
model openai:gpt-5.4-mini
Plan running
Reviews 0
```

SQLite persisted only the initial events for the browser run, and this remained
unchanged after repeated polling for more than four minutes:

```text
1 message/user ok       User request
2 status/session running Workbench run queued
3 status/capability_profile_updated ok Capability profile resolved
```

No tool calls were recorded. No workflow events or workflow snapshots were
recorded for the run id. No files were created in the temp workspace.

A foreground reproduction of the same CLI path with `--approve always` failed
immediately:

```text
** (Mix) invalid runic_ai.agent approve
```

The code path explains the mismatch:

- `RunicAI.Workbench` accepts `"always"` and `"all"` in `@approval_choices`.
- `RunicAI.Terminal.CliOptions` accepts only `:never`, `:safe`, and `:ask`.
- Workbench converts the launch into CLI args, including `--approve always`.
- The background task parses those args after the session is already marked
  running.
- The parse failure is not persisted back to the session.

A control run with `--approve safe` reached dynamic workflow planning. The RLM
coordinator produced an accepted general workflow proposal, compiled it, and
started the first node, `explore_repo`. It then requested review for the first
`git status --short` command and failed in foreground non-interactive mode:

```text
Review required: rlm_node_execution
Checkpoint: pre_tool
Reason: gated_rlm_node
...
review prompt reached EOF before a decision
```

This means the dynamic planner is capable of producing a generic RayOps plan,
but the approval/supervision/presentation stack prevents the browser run from
reaching execution when approve-all is selected.

## Issues Observed

### Approval Policy Drift

Workbench and terminal approval policy enums are inconsistent. The browser can
submit `approve=always`, and Workbench can normalize it, but the terminal
runner rejects the same value. From a user perspective, an explicit "approve
all" selection starts a run that appears active and then silently does nothing.

Recommended resolution:

- Define one shared approval-policy type and parser used by Workbench, CLI, TUI,
  Terminal, and RLM runtime gates.
- Accept `always` everywhere it can be selected.
- Treat `all` as an alias at boundaries only, then normalize to `always`.
- Add integration coverage that launches through Workbench with `approve=always`
  and asserts at least one post-launch RLM event or an explicit failed status.

### Background Task Failures Are Not Durable

Workbench records the user event, queued event, and capability event before
starting the background runner. If the runner fails during CLI parsing or other
startup work, the browser session remains `running` indefinitely. The failure is
not visible in terminal events, workflow run status, review requests, or the UI.

Recommended resolution:

- Wrap the entire background task body in a top-level error boundary that
  records a terminal error event and updates both `agent_sessions` and
  `workflow_runs` to `failed`.
- Parse and validate CLI-equivalent options before recording a successful
  queued/running launch, or persist a distinct `launch_failed` event if startup
  validation fails.
- Monitor supervised tasks and persist abnormal exits.
- Add a stale-running detector for sessions with no event progress after a
  startup grace period.

### Session Metadata Loses Launch Configuration

The browser run's workflow metadata contained the Vmsan capability profile, but
`agent_sessions.metadata_json` showed `approval`, `capability_profile`, and
`mode` as `null`. The session page then rendered the follow-up composer as
`standard` and `safe auto-approve` even though the active session was RLM with
approve-all.

Recommended resolution:

- Persist normalized launch configuration on `agent_sessions` at creation:
  `agent`, `mode`, `approval`, `write_policy`, `model`, `sandbox`, selected
  runtime, runtimes, network, and workspace root.
- Hydrate the session composer from the active session defaults, not global
  Workbench defaults.
- Show the selected sandbox and approval policy in the session header and make
  discrepancies between selected and effective policy visible.

### Vmsan Selection Is Not First-Class In The Visible Form

The hidden browser payload accepted `sandbox_backend=vmsan`, and the backend
capability profile used `code_execution.backend=vmsan`. The visible settings
select, however, listed `just_bash`, `docker`, `gvisor`, and `firecracker`, but
not `vmsan`. During form changes the compact summary briefly rendered "No
available sandbox selected" while the hidden fields still held Vmsan values.

Recommended resolution:

- Render every backend accepted by backend normalization in the visible sandbox
  selector, including `vmsan`.
- Drive the compact sandbox summary from the same normalized selected sandbox
  model that will be submitted.
- Add browser tests that change each supported sandbox backend and assert the
  visible summary, submitted payload, and persisted capability profile agree.

### No Sandbox Proof Was Produced

The run's capability profile said Vmsan was selected, but the failed browser run
never opened a sandbox session or executed a sandbox command. The safe-mode
control run reached a proposal and then failed before command execution. There
was therefore no proof that the RayOps work actually ran inside Vmsan.

Recommended resolution:

- Emit an explicit sandbox preflight event before the first RLM node executes:
  backend, runtime, workspace mode, network mode, and a health/proof marker.
- Make "selected sandbox" and "effective execution backend" separate fields.
- For Vmsan, require a cheap `sandbox_status` or `open_sandbox_session` proof
  before claiming the run is using microVM sandboxing.

### Review Gating Blocks Basic Read-Only Progress

The safe-mode control run gated the first `git status --short` node as
`rlm_node_execution`. In non-interactive mode, the review prompt reached EOF and
the run failed. In browser mode, approve-all should have bypassed this gate, but
the approval parser mismatch prevented startup.

Recommended resolution:

- Route all RLM node review gates through the same runtime policy engine,
  including command, sandbox, patch, and generated workflow nodes.
- Mark read-only commands such as `git status`, `ls`, and source reads as
  low-risk under safe mode when workspace policy allows them.
- In headless/non-interactive runs, fail fast with an explicit error if a
  required review cannot be satisfied, rather than prompting stdin and treating
  EOF as a late node failure.
- Keep objective budget approvals separate from tool approval policy.

### Empty Workspace Expectations Are Ambiguous

The RayOps prompt asks for a Phoenix/Ecto/LiveView application. The isolated
workspace was intentionally empty to avoid modifying RunicAI. The generated
proposal assumed an Elixir/Phoenix application workspace was available. A
general-purpose coding agent needs to distinguish "add feature to this app"
from "create a new app here" before planning tool execution.

Recommended resolution:

- Add an environment classification step before proposal generation:
  existing app, empty workspace, non-matching stack, or ambiguous.
- If the workspace is empty and the prompt asks for a named application, plan a
  project bootstrap path or ask for approval/constraints before bootstrapping.
- If network is disabled and dependencies are not locally available, surface
  that constraint before generating an implementation plan that requires package
  installation.

## General Architecture Recommendations

The durable fix is to treat launch policy and runtime policy as one shared
contract, not a browser concern layered over terminal behavior. The Workbench,
CLI, TUI, dynamic workflow compiler, RLM node executor, sandbox runtime, and
review UI should all consume the same normalized launch struct.

Use this launch lifecycle:

1. Normalize and validate request.
2. Persist complete launch config.
3. Resolve capability profile.
4. Preflight model/client and sandbox.
5. Start monitored runner.
6. Persist every terminal state transition, including startup failure.
7. Hydrate UI from persisted state only.

For user trust, the UI should never show a session as simply "running" when no
runner is alive, no durable event has advanced, and no review is pending. That
state should become `launch_failed`, `stalled`, or `waiting_for_review` with a
specific reason and a next action.

## Follow-Up Test Cases

- Browser launch RLM patch with `approve=always`, Vmsan, and a read-only prompt;
  assert the first RLM event after capability resolution is recorded.
- Browser launch RLM patch with `approve=always`, Vmsan, and the RayOps prompt;
  assert proposal, compile, sandbox preflight, and first node execution events.
- Browser launch RLM patch with `approve=safe`; assert the first non-safe review
  appears in the Reviews tab and can be changed to approve-all mid-session.
- CLI launch with `--approve always`; assert it parses and auto-allows tool
  reviews, or explicitly document that CLI does not support approve-all and
  prevent Workbench from forwarding it.
- Stale-run regression: force `CliOptions.parse/1` to return an error after
  Workbench records the launch and assert the session is marked failed with a
  visible error event.
