# Coding Harness

Use `RunicAI.Coding` when an agent needs to inspect a local workspace, apply
structured patches, run bounded project commands, and keep traceable evidence
about what happened. The harness is intentionally a substrate rather than a full
agent loop: standard coding agents and RLM-generated coding workflows should use
the same tools and policies.

## Direct Tool Use

```elixir
alias RunicAI.Coding.CommandPolicy
alias RunicAI.Coding.Tools
alias RunicAI.Coding.Workspace

workspace = Workspace.new!(root: File.cwd!())

policy =
  CommandPolicy.new!(
    allowed_commands: ["mix", "git"],
    timeout_ms: 30_000,
    max_output_bytes: 64_000
  )

registry = Tools.default_registry(workspace, command_policy: policy)

{:ok, listing} = Tools.list_dir(workspace, %{path: "lib"})
{:ok, result} = Tools.run_profile_task(workspace, :run_tests, %{}, policy)
```

All file paths resolve through the workspace root and `PathPolicy`. Mutating file
operations go through `apply_patch`, which returns changed paths, hashes, and
repairable diagnostics.

## IntegratedToolAgent

The default registry can be passed directly to `RunicAI.Recipes.IntegratedToolAgent`.
Most callers should expose a narrow visible tool set and keep shell access off by
default.

```elixir
alias Runic.Workflow
alias RunicAI.Coding.CommandPolicy
alias RunicAI.Coding.Tools
alias RunicAI.Coding.Workspace
alias RunicAI.Recipes.IntegratedToolAgent

workspace = Workspace.new!(root: "/path/to/project")

command_policy =
  CommandPolicy.new!(
    allowed_commands: ["mix", "git"],
    allow_shell: false,
    timeout_ms: 30_000
  )

registry = Tools.default_registry(workspace, command_policy: command_policy)

workflow =
  IntegratedToolAgent.new(
    model: "openai:gpt-5.4-mini",
    registry: registry,
    visible_tools: [
      "list_dir",
      "find_files",
      "read_file",
      "search_text",
      "apply_patch",
      "run_tests"
    ],
    tool_requirement: :required,
    max_turns: 8,
    system: "Inspect the workspace, patch only the bug, then run the tests."
  )
  |> Workflow.react_until_satisfied(%{user: "Fix the failing test."})
```

## Artifacts And Persistence

Large reads and command outputs are returned as previews. When the workspace has
persistence configured, the full payload is stored behind an artifact ref.

```elixir
alias RunicAI.Coding.Persistence
alias RunicAI.Coding.Persistence.InMemory
alias RunicAI.Coding.Workspace

{:ok, store} = InMemory.start_link()

workspace =
  Workspace.new!(
    root: File.cwd!(),
    persistence: {InMemory, store}
  )

{:ok, file} = RunicAI.Coding.Tools.read_file(workspace, %{path: "mix.exs", max_bytes: 200})
{:ok, artifact} = Persistence.get_artifact(workspace.persistence, file.artifact_ref)
```

`RunicAI.Coding.Persistence.SQLite` is available when the optional `:exqlite`
dependency is present. The in-memory store remains the first-class development
path.

## Optional JustBash Backend

`run_command` defaults to direct argv execution. A guarded host shell is
available with `allow_shell: true`, and an optional `:just_bash` backend can run
shell snippets against an in-memory filesystem when the `:just_bash` dependency
is present.

```elixir
policy = CommandPolicy.new!(allowed_commands: ["just_bash"])

Tools.run_command(
  workspace,
  %{
    backend: "just_bash",
    command: "cat /workspace/README.md",
    metadata: %{files: %{"/workspace/README.md" => "hello\n"}}
  },
  policy
)
```

## Terminal Smoke

The Mix task exercises the same tool layer without a full model loop.

```bash
mix runic_ai.coding.smoke --cwd .
mix runic_ai.coding.smoke --cwd . --test
```

Use `--session-id`, `--profile mix`, and `--tools list_dir,read_file,run_tests`
when you want the output to mirror a specific terminal agent run.

## Codex Bridge

`RunicAI.Coding.Codex.ExecClient` wraps `codex exec --json` for local,
subscription-backed experiments. It assumes the Codex CLI is already installed
and authenticated by the user. The bridge does not read or copy Codex credential
files; it only invokes the CLI under the configured workspace, sandbox, approval,
timeout, and output policies.
