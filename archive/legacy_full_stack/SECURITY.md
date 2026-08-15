# Security

RunicAI composes model calls, tool execution, runtime sessions, trace capture,
and persistence. Treat those boundaries as application security boundaries.

## Tool Execution

Tools can perform real actions. Validate tool inputs, enforce authorization in
your application, and prefer guarded recipes when a tool can mutate external
state, spend money, disclose data, send messages, run commands, or trigger
irreversible work.

For high-risk tools:

- add a pre-tool guard
- return `RunicAI.ReviewRequest` for human approval
- record the decision with `RunicAI.ReviewDecision`
- enforce budgets with `RunicAI.Control.BudgetPolicy`
- keep a trace with sensitive payload capture disabled or redacted

## Command And External Worker Adapters

Command and external-worker adapters should be configured as narrowly as
possible. Avoid passing untrusted model output directly into shell commands,
file paths, network destinations, credentials, or serialized worker payloads.

Use allowlists for command names, arguments, working directories, environment
variables, and worker capabilities.

## Secrets

Do not place provider API keys, service credentials, or tenant secrets in
prompts, trace payloads, evaluation fixtures, Livebooks, or checked-in example
configuration.

When using ReqLLM-backed clients, follow the provider and ReqLLM guidance for
credential configuration.

## Trace Payloads

`RunicAI.Trace.CapturePolicy` controls how much payload data is captured.
Choose the smallest capture mode that supports your debugging or replay need.
Use redaction before traces leave a trusted boundary.

Replay-grade traces are powerful regression artifacts, but they may contain
prompt text, tool arguments, tool outputs, retrieved documents, user data, or
operator decisions.

## Persistence And Runtime Sessions

Persisted sessions and runner stores may contain conversation state, context
state, pending work, waits, reviews, tool observations, and trace identifiers.
Protect them with the same access controls as your application data.

## Reporting

This repository does not yet publish a formal vulnerability disclosure channel.
Until one exists, report security concerns through the repository maintainer or
private project channel used by your deployment.
