defmodule RunicAI.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/zblanco/runic_ai"

  def project do
    [
      app: :runic_ai,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {RunicAI.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:runic, "~> 0.1.0-alpha.7"},
      {:req_llm, "~> 1.9"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end

  defp description do
    "Workflow-native AI components, contracts, recipes, and runtime adapters built on Runic and ReqLLM."
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md CHANGELOG.md SECURITY.md guides livebooks .formatter.exs),
      links: %{
        "GitHub" => @source_url,
        "Runic" => "https://hex.pm/packages/runic",
        "ReqLLM" => "https://hex.pm/packages/req_llm"
      }
    ]
  end

  defp docs do
    [
      main: "RunicAI",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: @source_url,
      before_closing_body_tag: &before_closing_body_tag/1,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "guides/getting-started.md",
        "guides/mental-model.md",
        "guides/workflows-as-composition.md",
        "guides/contracts.md",
        "guides/context-engineering.md",
        "guides/controls-and-limits.md",
        "guides/stateless-vs-stateful-agents.md",
        "guides/recipes/chat-agent.md",
        "guides/recipes/tool-agent.md",
        "guides/recipes/controlled-tool-agent.md",
        "guides/recipes/context-aware-agent.md",
        "guides/recipes/subagent-decomposition.md",
        "guides/recipes/integrated-stateful-agent.md",
        "guides/recipes/evaluation-harness.md",
        "guides/recipes/rlm-summarizer.md",
        "guides/extending/components.md",
        "guides/extending/tools.md",
        "guides/extending/telemetry-and-tracing.md",
        "guides/extending/authorization-and-guards.md",
        "guides/extending/persistence-and-runtime.md",
        "guides/extending/causal-logging.md",
        "guides/reference/component-catalog.md",
        "guides/reference/testing-strategy.md",
        "guides/reference/release-checklist.md",
        "livebooks/getting-started.livemd",
        "livebooks/chat-agent-kernel.livemd",
        "livebooks/tool-agent.livemd",
        "livebooks/controlled-tool-agent.livemd",
        "livebooks/context-engineering.livemd",
        "livebooks/context-aware-agent.livemd",
        "livebooks/integrated-stateful-agent.livemd",
        "livebooks/subagent-decomposition.livemd",
        "livebooks/evaluation-harness.livemd",
        "livebooks/rlm-summarizer.livemd",
        "livebooks/runtime-tracing-replay.livemd"
      ],
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        RunicAI.Agent,
        RunicAI.Candidate,
        RunicAI.Context,
        RunicAI.Control,
        RunicAI.Decomposition,
        RunicAI.Evaluation,
        RunicAI.Harness,
        RunicAI.Integrated,
        RunicAI.Memory,
        RunicAI.Optimization,
        RunicAI.Recipes,
        RunicAI.Retrieval,
        RunicAI.RLM,
        RunicAI.Runtime,
        RunicAI.Steps,
        RunicAI.Testing,
        RunicAI.Tool,
        RunicAI.Trace
      ]
    ]
  end

  defp groups_for_extras do
    [
      "Start Here": [
        "README.md",
        "guides/getting-started.md",
        "guides/mental-model.md"
      ],
      "Core Concepts": [
        "guides/workflows-as-composition.md",
        "guides/contracts.md",
        "guides/context-engineering.md",
        "guides/controls-and-limits.md",
        "guides/stateless-vs-stateful-agents.md"
      ],
      Recipes: ~r"guides/recipes/",
      "Extending RunicAI": ~r"guides/extending/",
      Reference: ["CHANGELOG.md", "SECURITY.md", ~r"guides/reference/"],
      Livebooks: ~r"livebooks/"
    ]
  end

  defp groups_for_modules do
    [
      Overview: [RunicAI],
      "Core Contracts": [
        RunicAI.Message,
        RunicAI.Prompt,
        RunicAI.Conversation,
        RunicAI.Conversation.State,
        RunicAI.Error,
        RunicAI.Wait,
        RunicAI.ResumeSignal,
        RunicAI.ReviewRequest,
        RunicAI.ReviewDecision
      ],
      "LLM Access": [
        RunicAI.LLM,
        RunicAI.LLM.Request,
        RunicAI.LLM.Result,
        RunicAI.LLM.ReqLLMClient
      ],
      "Agent Turns": ~r"RunicAI\.Agent\.",
      "Workflow Steps": ~r"RunicAI\.Steps\.",
      "Workflow Rules": ~r"RunicAI\.Rules\.",
      Tools: ~r"RunicAI\.Tool\.",
      Control: ~r"RunicAI\.Control\.",
      "Context, Memory, And Retrieval": ~r"RunicAI\.(Context|Memory|Retrieval)\.",
      "Decomposition And Subagents": ~r"RunicAI\.(Decomposition|Candidate)\.",
      "Integrated Stateful Agents": ~r"RunicAI\.Integrated\.",
      Recipes: ~r"RunicAI\.Recipes\.",
      Runtime: ~r"RunicAI\.Runtime\.",
      "Tracing, Harnesses, Testing, And Evaluation":
        ~r"RunicAI\.(Trace|Harness|Testing|Evaluation)\.",
      "RLM And Long-Context Workflows": ~r"RunicAI\.RLM",
      Optimization: ~r"RunicAI\.Optimization\."
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
    <script>
      let runicAiMermaidInitialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!runicAiMermaidInitialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          runicAiMermaidInitialized = true;
        }

        let id = 0;

        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "runic-ai-mermaid-" + id++;

          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
