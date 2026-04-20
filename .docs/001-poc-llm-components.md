# POC: Core LLM Components for RunicAI

Note: this POC document is now partly superseded by
`.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md` and the
implemented Phase 0 contract layer. The canonical API now centers
`RunicAI.Message`, `RunicAI.Prompt`, `RunicAI.Conversation.State`,
`RunicAI.LLM.Request`, and `RunicAI.LLM.Result`.

## Goal

Build the foundational Runic components for LLM interactions. Every component is a
plain Runic construct (Step, Rule, Accumulator, StateMachine) that users compose
into workflows. LLM access flows through `RunicAI.LLM`, a thin facade that
delegates to a `:client` passed via opts — no Mox, no app config, just functions
and modules passed as data.

## Design: LLM Dependency Injection

The `RunicAI.LLM` module is a **behaviour + facade**. All public functions accept
an optional `:client` keyword:

```elixir
# Default: delegates to ReqLLM
RunicAI.LLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

# Explicit module client
RunicAI.LLM.generate_text("anthropic:claude-haiku-4-5", "Hello", client: MyClient)

# Inline function client (great for tests)
RunicAI.LLM.generate_text("model", "Hello",
  client: fn _model, _prompt, _opts -> {:ok, fake_response("Hi!")} end
)
```

The `:client` can be:
- **A module** implementing `RunicAI.LLM` behaviour (default: `RunicAI.LLM.ReqLLMClient`)
- **A function** matching the arity of the called function (2 or 3 for generate_text, etc.)

For Runic components, the client is threaded through via Runic's `context/1` or
passed directly as part of the input map.

## Testing Strategy

No Mox. Tests use a `RunicAI.LLM.TestClient` module in `test/support/` that
returns deterministic canned responses. Tests can also pass inline anonymous
functions for one-off scenarios:

```elixir
test "my component works" do
  client = fn _model, _prompt, _opts ->
    {:ok, RunicAI.LLM.TestClient.response("Expected answer")}
  end

  # pass client into the component under test
end
```

`TestClient` provides helpers to build well-formed `ReqLLM.Response` structs
so tests don't need to know the internals of ReqLLM's data model.

## Components to Build

### 1. `RunicAI.LLM` — Behaviour + Facade (refactor)

Refactor the existing module:
- Remove app-config-based client lookup
- Accept `:client` opt (module or function) in `generate_text/3`, `stream_text/3`, `generate_object/4`
- Default to `RunicAI.LLM.ReqLLMClient` when no `:client` is provided
- Keep the behaviour callbacks for module-based clients

### 2. `RunicAI.Steps.LLMGenerate` — Runic Step for text generation

A step constructor that wraps `RunicAI.LLM.generate_text/3`. Input is a map with
`:model`, `:prompt`, and optionally `:client` + extra opts. Returns the response.

```elixir
step = RunicAI.Steps.LLMGenerate.new(name: :generate)
# Input: %{model: "anthropic:claude-haiku-4-5", prompt: "Hello", client: test_fn}
# Output: {:ok, %ReqLLM.Response{...}}
```

### 3. `RunicAI.Steps.PromptBuilder` — Build Context from parts

A step that takes a map with `:system`, `:user` (and optionally `:history`) and
produces a `ReqLLM.Context`. This is the canonical way to assemble prompts.

```elixir
step = RunicAI.Steps.PromptBuilder.new(name: :build_prompt)
# Input: %{system: "You are helpful", user: "Hi", history: []}
# Output: %ReqLLM.Context{...}
```

### 4. `RunicAI.Steps.TextToConversation` — Parse text into messages

Converts a plain text exchange (or a response) into a structured conversation
context. Useful for seeding history from logs or text blobs.

```elixir
step = RunicAI.Steps.TextToConversation.new(name: :to_convo)
# Input: %{text: "User: Hi\nAssistant: Hello!", roles: [:user, :assistant]}
# or simpler: turn a single response text + original prompt into a context
```

### 5. `RunicAI.Conversation` — Conversation accumulator

A stateful accumulator that maintains conversation history. Each turn appends
user + assistant messages. Rules can gate whether to continue or stop.

```elixir
# The accumulator holds a %{context: %ReqLLM.Context{}, turns: integer()}
# Reducer: takes a new turn %{user: "...", assistant: "..."} and appends to context
# Reactors: fire when turn limit reached, or when assistant says "DONE", etc.
```

### 6. Basic Conversation Workflow

Compose the above into a simple conversation loop workflow:
1. PromptBuilder → builds initial context
2. LLMGenerate → calls the LLM
3. Conversation accumulator → tracks history
4. Rules → check stop conditions (max turns, stop token, etc.)

## File Layout

```
lib/runic_ai/
  llm.ex                          # Behaviour + facade (refactored)
  llm/
    req_llm_client.ex             # Default ReqLLM adapter
  steps/
    llm_generate.ex               # LLM text generation step
    prompt_builder.ex             # Prompt/context assembly step
    text_to_conversation.ex       # Text → Context conversion
  conversation.ex                 # Conversation accumulator + stop rules

test/support/
  llm_test_client.ex              # Fake LLM client for tests

test/
  runic_ai/
    llm_test.exs                  # LLM facade tests
    steps/
      llm_generate_test.exs       # LLM step tests
      prompt_builder_test.exs     # Prompt builder tests
      text_to_conversation_test.exs
    conversation_test.exs         # Conversation loop tests
```

## Future Considerations (not in this POC)

- Retry/fallback wrappers (Saga or Rule-based)
- Streaming step variants (compose stream_text)
- Tool-use loop (tool calls → execute → feed back)
- RAG components (retrieval step → context injection)
- Memory systems (long-term conversation storage)
- Nx integration (embeddings, local models)
- Explorer/DataFrame integration (structured data analysis)
- Scheduling policies for rate limiting / cost control
- LiveBook integration examples
