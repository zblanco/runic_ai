# RunicAI Agent Guide

RunicAI is a toolbox of AI components built on top of [Runic](https://hex.pm/packages/runic) workflows
and [ReqLLM](https://hex.pm/packages/req_llm). It provides reusable building blocks for constructing
AI agent loops, LLM workflow steps, error-handling control flow, scheduling policies, fallback
patterns, and more — all composed as Runic workflow graphs.

## Build/Test Commands
- `mix test` - Run all tests
- `mix test test/specific_test.exs` - Run specific test file
- `mix test test/specific_test.exs:123` - Run specific test line
- `mix compile` - Compile the project
- `mix format` - Format code according to .formatter.exs
- `mix deps.get` - Get dependencies

## Architecture

### Dependencies
- **Runic** (`~> 0.1.0-alpha.7`) — Workflow composition engine (DAG-based, lazy, process-agnostic)
- **ReqLLM** (`~> 1.9`) — Unified LLM provider interface (Anthropic, OpenAI, Google, etc.)

### Key Design Decisions
- **`RunicAI.LLM` behaviour** — A thin behaviour mirroring ReqLLM's high-level API (`generate_text`, `stream_text`, `generate_object`). The default implementation delegates to ReqLLM. All functions accept an optional `:client` opt (module or function) for dependency injection — no Mox or app config needed.
- **Components are Runic-native** — Every AI building block (agent loops, LLM steps, retry/fallback wrappers) is a Runic component (`Step`, `Rule`, `Accumulator`, etc.) composable into `Runic.Workflow` graphs.
- **No process assumptions** — Following Runic's philosophy, components are pure data structures evaluated lazily. Users choose their own process topology (GenServer, GenStage, bare Task, etc.).
- **Vanilla DI for tests** — Tests pass fake client functions/modules directly via `:client` opt. `RunicAI.LLM.TestClient` in `test/support/` provides canned responses.

### Module Layout
```
lib/runic_ai.ex                         # Top-level module & public API
lib/runic_ai/
  application.ex                        # OTP Application (supervision tree)
  llm.ex                                # LLM behaviour + facade with :client DI
  llm/req_llm_client.ex                 # Default ReqLLM adapter
  steps/
    llm_generate.ex                     # Step: call LLM generate_text
    prompt_builder.ex                   # Step: assemble ReqLLM.Context from parts
    text_to_conversation.ex             # Step: text/turns → ReqLLM.Context
  conversation.ex                       # Accumulator: conversation history tracking
test/support/
  llm_test_client.ex                    # Fake LLM client for tests
```

## Runic Quick Reference

Always `require Runic` before using macros. Consider `import Runic` as well.

### Core Components
| Component | Constructor | Purpose |
|-----------|-------------|---------|
| Step | `Runic.step(fn x -> ... end, name: :name)` | Input → output transformation |
| Rule | `Runic.rule(fn x when guard -> result end)` | Conditional logic with guards |
| StateMachine | `Runic.state_machine(name: :n, init: val, reducer: fn)` | Stateful reductions |
| Accumulator | `Runic.accumulator(init, reducer, name: :n)` | Running totals/counters |
| Map | `Runic.map(fn x -> ... end, name: :n)` | Per-element transformation |
| Reduce | `Runic.reduce(init, fn x, acc -> ... end, name: :n)` | Collection aggregation |
| FSM | `Runic.fsm name: :n do ... end` | Finite state machine |
| Aggregate | `Runic.aggregate name: :n do ... end` | Event-sourced aggregate |
| Saga | `Runic.saga name: :n do ... end` | Distributed transaction with compensation |
| ProcessManager | `Runic.process_manager name: :n do ... end` | Long-running process orchestration |

### Workflow Construction
```elixir
# Declarative (static structure)
workflow = Runic.workflow(
  name: :pipeline,
  steps: [
    {Runic.step(&parse/1, name: :parse),
     [Runic.step(&transform/1, name: :transform)]}
  ]
)

# Imperative (dynamic/runtime construction)
workflow = Workflow.new(name: :dynamic)
  |> Workflow.add(step_a)
  |> Workflow.add(step_b, to: :step_a_name)
  |> Workflow.add(join_step, to: [:a, :b])  # fan-in
```

### Evaluation
```elixir
# Simple: run to completion
workflow = Workflow.react_until_satisfied(workflow, input)

# Parallel (I/O-bound)
workflow = Workflow.react_until_satisfied(workflow, input, async: true, timeout: :infinity)

# Results
Workflow.results(workflow)                    # structured via output ports
Workflow.results(workflow, [:step_name])      # specific components
Workflow.raw_productions(workflow)            # all raw values
```

### Runtime Context
```elixir
# Inject secrets/config into components at runtime
step = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)

Workflow.react_until_satisfied(workflow, input,
  run_context: %{call_llm: %{api_key: "sk-..."}}
)
```

### Runic Rules
1. **Always `require Runic`** before macros
2. **Always name components** for debugging and referencing
3. **Use `^variable`** to pin runtime values (required for serialization)
4. **Extract results** via `Workflow.results/1` or `Workflow.raw_productions/1`, never direct graph access
5. **Check `Workflow.is_runnable?/1`** before calling `react/2` in loops

## ReqLLM Quick Reference

```elixir
# Text generation
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", "Hello")
text = ReqLLM.generate_text!("anthropic:claude-haiku-4-5", "Hello")

# Streaming
{:ok, response} = ReqLLM.stream_text("anthropic:claude-haiku-4-5", "Write a story")
ReqLLM.StreamResponse.tokens(response) |> Stream.each(&IO.write/1) |> Stream.run()

# Structured output
schema = [name: [type: :string, required: true], age: [type: :pos_integer]]
person = ReqLLM.generate_object!("anthropic:claude-haiku-4-5", "Generate a person", schema)

# With context (multi-turn)
context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are a helpful assistant"),
  ReqLLM.Context.user("Explain recursion")
])
{:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4-5", context)

# Tool use
tool = ReqLLM.tool(
  name: "get_weather",
  description: "Get weather for a location",
  parameter_schema: [location: [type: :string, required: true]],
  callback: {Weather, :fetch, []}
)
{:ok, response} = ReqLLM.generate_text(model, "Weather in Paris?", tools: [tool])
```

## Code Style & Conventions
- Run `mix format` before committing
- Follow Elixir naming: `snake_case` for variables/functions, `PascalCase` for modules
- Pattern matching preferred over conditionals
- Use `with` for chaining `{:ok, _}` / `{:error, _}` operations
- Protocols for extensible behaviour (follow Runic's `Invokable`, `Component` patterns)
- Module attributes for compile-time configuration
- **One module per file** — never nest multiple modules (causes cyclic dependency / compilation errors)

## Phoenix LiveView UI Preferences

For future RunicAI-associated Phoenix/LiveView work, an in-repo Phoenix graft is acceptable: Phoenix and web dependencies may live in this app when the goal is a single local RunicAI product. A separate sibling `runic_ai_web` path-dependency app is also acceptable for early isolation. Do not default to an umbrella unless separate release composition becomes a real requirement.

- Default to a dark/night-mode theme derived from `.docs/DESIGN.md`.
- Prefer the `Inter` font, backdrop blur, opacity, rounded edges, and restrained dark surfaces.
- Tailwind CSS v4 uses `app.css` as a configuration surface. Keep that file focused on Tailwind setup, theme/design tokens, fonts, plugins, and focused CSS only when Tailwind or component composition is not enough.
- Prefer colocated HEEx markup with Tailwind classes and reusable Phoenix components over broad custom CSS.
- Use Phoenix's built-in Heroicons path through `<.icon>` for normal UI icons.
- Use `mount/3` for stable defaults, empty streams, subscriptions, and assign shape.
- Use `handle_params/3` for loading route/query-param aware data, especially database filters, selected tabs, pagination, search, and current resource selection.
- Use `handle_event/3` for server-side actions such as starting runs, submitting prompts, approving tools, changing persisted settings, replaying workflows, or cancelling sessions.
- Use Phoenix JS commands or hooks for purely client-side behavior such as dropdowns, disclosure state, focus management, auto-scroll, Mermaid rendering, clipboard actions, and local measurements.
- Use MDEx for Markdown rendering and Mermaid JS for browser-side Mermaid diagrams, with dark-mode styling by default.
- Keep LiveView pages backed by durable RunicAI query/read-model APIs where practical rather than relying on large in-memory assigns.

## Elixir Rules

- Elixir lists **do not support index access** via `[]`. Use `Enum.at/2`, pattern matching, or `List` functions.
- Elixir **does NOT** support `if/else if` or `if/elsif`. Use `cond` or `case` for multiple branches.
- Variables are immutable but rebindable. Block expressions (`if`, `case`, `cond`) must bind their result:
  ```elixir
  # ✅ Correct
  socket = if connected?(socket), do: assign(socket, :val, val), else: socket

  # ❌ Wrong — rebinding inside the block has no effect outside
  if connected?(socket), do: socket = assign(socket, :val, val)
  ```
- **Never** use `String.to_atom/1` on user input (atoms are never garbage collected)
- **Never** use map access syntax (`struct[:field]`) on structs — use `struct.field`
- Predicate functions end with `?` (e.g. `valid?/1`); reserve `is_` prefix for guards
- Use `Task.async_stream/3` for concurrent enumeration (usually with `timeout: :infinity`)
- `try/catch` is rarely needed in good Elixir code and while not always, tends to be a smell that a bandaid fix is being applied and if you find yourself writing a try/catch its worth stepping back and analyzing why. Error handling in Elixir/Erlang can often let the exception happen to kill the process and let the supervision tree contain the error but only in the case where we need to specifically control an exception like around a CMD / external IO or compilation factor is a try/catch reasonable over a with/case/if/etc control flow.

## Mix Rules
- Read docs before using tasks: `mix help task_name`
- Debug test failures: `mix test test/file.exs` or `mix test --failed`
- `mix deps.clean --all` is almost never needed — avoid unless you have a good reason
