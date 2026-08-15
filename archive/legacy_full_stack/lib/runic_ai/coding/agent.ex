defmodule RunicAI.Coding.Agent do
  @moduledoc """
  Standard local coding-agent recipe.

  This module is a narrow wrapper around `RunicAI.Recipes.IntegratedToolAgent`.
  It provides mode-specific tool profiles, coding prompts, safe command policy
  defaults, and summary helpers while reusing the shared coding harness for all
  filesystem, patch, git, and command behavior.
  """

  alias Runic.Workflow
  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Coding.AgentState
  alias RunicAI.Coding.Codex
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.Prompt
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.RecipeSelector
  alias RunicAI.Coding.ReviewGate
  alias RunicAI.Coding.StandardAgent.ObjectiveGate
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Control.BudgetPolicy
  alias RunicAI.LLM.Retry, as: LLMRetry
  alias RunicAI.Recipes.IntegratedToolAgent
  alias RunicAI.Tool.Registry

  @default_agent_id "coding"
  @default_model "openai:gpt-5.4-mini"

  @type mode :: Recipe.mode()

  @spec initial_runtime(keyword()) :: RunicAI.Integrated.RuntimeState.t()
  def initial_runtime(opts \\ []) when is_list(opts) do
    {workspace_input, opts} = normalize_new_args(opts, [])
    workspace = Workspace.from_input!(workspace_input)
    recipe = recipe_from_opts(opts)
    capabilities = resolved_capabilities_from_opts(workspace, recipe, opts)
    command_policy = command_policy_from_opts(recipe, opts, capabilities)
    registry = registry_from_opts(workspace, recipe, command_policy, opts, capabilities)
    recipe = recipe_with_capabilities(recipe, capabilities)

    workspace
    |> integrated_opts(recipe, command_policy, registry, opts, capabilities)
    |> maybe_put_client(opts)
    |> IntegratedToolAgent.initial_runtime()
  end

  @spec new(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: Workflow.t()
  def new(workspace_input, opts \\ []) when is_list(opts) do
    {workspace_input, opts} = normalize_new_args(workspace_input, opts)
    workspace = Workspace.from_input!(workspace_input)
    recipe = recipe_from_opts(opts)
    capabilities = resolved_capabilities_from_opts(workspace, recipe, opts)
    command_policy = command_policy_from_opts(recipe, opts, capabilities)
    registry = registry_from_opts(workspace, recipe, command_policy, opts, capabilities)
    recipe = recipe_with_capabilities(recipe, capabilities)

    workspace
    |> integrated_opts(recipe, command_policy, registry, opts, capabilities)
    |> maybe_put_client(opts)
    |> IntegratedToolAgent.new()
  end

  @spec run(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) :: Workflow.t()
  def run(workspace_input, task, opts \\ [])
      when is_binary(task) and is_list(opts) do
    workspace = Workspace.from_input!(workspace_input)
    recipe = recipe_from_task(task, opts)
    opts = Keyword.put_new(opts, :objective, task)

    workflow =
      workspace
      |> new(Keyword.put(opts, :recipe, recipe))
      |> Workflow.react_until_satisfied(%{
        agent_id: Keyword.get(opts, :agent_id, @default_agent_id),
        user: Prompt.user(task, workspace, recipe, opts)
      })

    maybe_run_objective_loop(workflow, workspace, task, recipe, opts)
  end

  defp maybe_run_objective_loop(
         %Workflow{} = workflow,
         %Workspace{} = workspace,
         objective,
         recipe,
         opts
       ) do
    if Keyword.get(opts, :objective_gate?, false) do
      objective_opts =
        opts
        |> Keyword.put_new(:require_changes?, recipe.mode in [:patch, :verify])
        |> Keyword.put_new(:require_verification?, recipe.mode == :verify)

      run_objective_loop(
        workflow,
        workspace,
        objective,
        recipe,
        objective_opts,
        Keyword.get(opts, :objective_gate_max_iterations, 4)
      )
    else
      workflow
    end
  end

  defp run_objective_loop(%Workflow{} = workflow, _workspace, _objective, _recipe, _opts, 0),
    do: workflow

  defp run_objective_loop(
         %Workflow{} = workflow,
         %Workspace{} = workspace,
         objective,
         recipe,
         opts,
         iterations_left
       ) do
    evaluation = objective_evaluation(workflow, workspace, objective, opts)

    if evaluation && ObjectiveGate.satisfied?(evaluation) do
      workflow
    else
      repair_prompt =
        (evaluation && evaluation.repair_prompt) ||
          "Continue repairing the objective with concrete verification evidence."

      workflow
      |> Workflow.react_until_satisfied(%{
        agent_id: Keyword.get(opts, :agent_id, @default_agent_id),
        user: repair_prompt <> "\n\nRun mode:\n" <> to_string(recipe.mode)
      })
      |> run_objective_loop(workspace, objective, recipe, opts, iterations_left - 1)
    end
  end

  @spec read_only(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) ::
          Workflow.t()
  def read_only(workspace_input, task, opts \\ []) do
    run(workspace_input, task, Keyword.merge([mode: :read_only], opts))
  end

  @spec patch(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) :: Workflow.t()
  def patch(workspace_input, task, opts \\ []) do
    run(workspace_input, task, Keyword.merge([mode: :patch], opts))
  end

  @spec verify(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) ::
          Workflow.t()
  def verify(workspace_input, task, opts \\ []) do
    run(workspace_input, task, Keyword.merge([mode: :verify], opts))
  end

  @spec default_registry(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: Registry.t()
  def default_registry(workspace_input, opts \\ []) do
    workspace = Workspace.from_input!(workspace_input)
    recipe = recipe_from_opts(opts)

    case resolved_capabilities_from_opts(workspace, recipe, opts) do
      %{registry: registry} ->
        registry

      nil ->
        Tools.default_registry(workspace,
          command_policy: command_policy_from_opts(recipe, opts),
          process_registry: Keyword.get(opts, :process_registry),
          patch_dry_run?: recipe.dry_run?,
          memory_store: Keyword.get(opts, :memory_store),
          memory_store_opts: Keyword.get(opts, :memory_store_opts),
          session_store: Keyword.get(opts, :session_store),
          event_sink: Keyword.get(opts, :event_sink)
        )
    end
  end

  @spec visible_tools(mode() | String.t() | atom()) :: [String.t()]
  def visible_tools(mode), do: Recipe.default_visible_tools(mode)

  @spec summary(Workflow.t(), String.t() | atom()) :: AgentState.summary()
  def summary(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    AgentState.summary(workflow, agent_id)
  end

  @spec objective_evaluation(
          Workflow.t(),
          Workspace.t() | keyword() | map() | Path.t(),
          String.t(),
          keyword()
        ) ::
          map() | nil
  def objective_evaluation(%Workflow{} = workflow, workspace_input, objective, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    with %{} = session <-
           IntegratedToolAgent.session(workflow, Keyword.get(opts, :agent_id, @default_agent_id)) do
      workspace = Workspace.from_input!(workspace_input)
      ObjectiveGate.evaluate(workspace, objective, session, opts)
    end
  end

  @spec trace_events(Workflow.t(), String.t() | atom()) :: [RunicAI.Trace.Event.t()]
  def trace_events(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    AgentState.trace_events(workflow, agent_id)
  end

  @spec runtime_state(Workflow.t()) :: RunicAI.Integrated.RuntimeState.t() | nil
  def runtime_state(%Workflow{} = workflow), do: IntegratedToolAgent.runtime_state(workflow)

  @spec emissions(Workflow.t()) :: [RunicAI.Integrated.Emission.t()]
  def emissions(%Workflow{} = workflow), do: IntegratedToolAgent.emissions(workflow)

  @spec latest_turn_result(Workflow.t(), String.t() | atom() | nil) ::
          RunicAI.Agent.TurnResult.t() | nil
  def latest_turn_result(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    IntegratedToolAgent.latest_turn_result(workflow, agent_id)
  end

  @spec latest_reply_text(Workflow.t(), String.t() | atom() | nil) :: String.t() | nil
  def latest_reply_text(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    IntegratedToolAgent.latest_reply_text(workflow, agent_id)
  end

  @spec latest_review_request(Workflow.t(), String.t() | atom() | nil) ::
          RunicAI.ReviewRequest.t() | nil
  def latest_review_request(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    IntegratedToolAgent.latest_review_request(workflow, agent_id)
  end

  @spec latest_wait(Workflow.t(), String.t() | atom() | nil) :: RunicAI.Wait.t() | nil
  def latest_wait(%Workflow{} = workflow, agent_id \\ @default_agent_id) do
    IntegratedToolAgent.latest_wait(workflow, agent_id)
  end

  @spec command_policy(Recipe.t() | mode() | String.t() | atom(), keyword()) :: CommandPolicy.t()
  def command_policy(recipe_or_mode, opts \\ [])

  def command_policy(%Recipe{} = recipe, opts), do: command_policy_from_opts(recipe, opts)

  def command_policy(mode, opts) do
    Recipe.new!(mode: mode)
    |> command_policy_from_opts(opts)
  end

  @spec select_recipe(String.t(), keyword()) :: Recipe.t()
  def select_recipe(task, opts \\ []) when is_binary(task) and is_list(opts) do
    RecipeSelector.select!(task, opts)
  end

  @spec client(:codex | module() | function()) :: module() | function()
  def client(input), do: normalize_client(input)

  defp recipe_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :recipe) ->
        Recipe.from_input!(Keyword.fetch!(opts, :recipe))

      Keyword.has_key?(opts, :command) ->
        Recipe.named(Keyword.fetch!(opts, :command))

      true ->
        Recipe.new!(
          mode: Keyword.get(opts, :mode, :verify),
          visible_tools:
            Keyword.get(
              opts,
              :visible_tools,
              Recipe.default_visible_tools(Keyword.get(opts, :mode, :verify))
            ),
          tool_requirement: Keyword.get(opts, :tool_requirement, :optional),
          max_turns:
            Keyword.get(opts, :max_turns, default_max_turns(Keyword.get(opts, :mode, :verify))),
          dry_run?: Keyword.get(opts, :dry_run?, false),
          verification_policy: Keyword.get(opts, :verification_policy, :targeted_first)
        )
    end
  end

  defp recipe_from_task(task, opts) do
    cond do
      Keyword.has_key?(opts, :recipe) or Keyword.has_key?(opts, :command) or
          Keyword.has_key?(opts, :mode) ->
        recipe_from_opts(opts)

      Keyword.get(opts, :auto_recipe?, false) or Keyword.get(opts, :select_recipe?, false) ->
        RecipeSelector.select!(task, opts)

      true ->
        recipe_from_opts(opts)
    end
  end

  defp command_policy_from_opts(recipe, opts, capabilities \\ nil)

  defp command_policy_from_opts(_recipe, _opts, %{command_policy: %CommandPolicy{} = policy}),
    do: policy

  defp command_policy_from_opts(%Recipe{} = recipe, opts, _capabilities) do
    case Keyword.get(opts, :command_policy) do
      nil ->
        CommandPolicy.new!(
          allowed_commands: allowed_commands(recipe),
          allow_shell: false,
          allow_just_bash: false,
          timeout_ms: Keyword.get(opts, :command_timeout_ms, 30_000),
          max_output_bytes: Keyword.get(opts, :command_max_output_bytes, 32_768),
          metadata: %{coding_agent_mode: recipe.mode}
        )

      input ->
        CommandPolicy.from_input!(input)
    end
  end

  defp allowed_commands(%Recipe{mode: :verify}), do: ["git", "mix"]
  defp allowed_commands(%Recipe{mode: _mode}), do: ["git"]

  defp registry_from_opts(
         %Workspace{} = _workspace,
         %Recipe{} = _recipe,
         _command_policy,
         _opts,
         %{registry: %Registry{} = registry}
       ),
       do: registry

  defp registry_from_opts(
         %Workspace{} = workspace,
         %Recipe{} = recipe,
         command_policy,
         opts,
         _capabilities
       ) do
    Keyword.get_lazy(opts, :registry, fn ->
      Tools.default_registry(workspace,
        command_policy: command_policy,
        process_registry: Keyword.get(opts, :process_registry),
        patch_dry_run?: recipe.dry_run?,
        memory_store: Keyword.get(opts, :memory_store),
        memory_store_opts: Keyword.get(opts, :memory_store_opts),
        session_store: Keyword.get(opts, :session_store),
        event_sink: Keyword.get(opts, :event_sink)
      )
    end)
  end

  defp integrated_opts(
         %Workspace{} = workspace,
         %Recipe{} = recipe,
         _command_policy,
         registry,
         opts,
         capabilities
       ) do
    [
      default_agent_id: Keyword.get(opts, :agent_id, @default_agent_id),
      model: Keyword.get(opts, :model, @default_model),
      registry: registry,
      initial_runtime: Keyword.get(opts, :initial_runtime),
      visible_tools: Keyword.get(opts, :visible_tools, recipe.visible_tools),
      tool_requirement: Keyword.get(opts, :tool_requirement, recipe.tool_requirement),
      max_turns: Keyword.get(opts, :max_turns, recipe.max_turns),
      system: Prompt.system(workspace, recipe, opts),
      llm_opts: llm_opts(workspace, opts),
      state_metadata: state_metadata(workspace, recipe, opts),
      metadata: turn_metadata(workspace, recipe, opts),
      execution_policy: Keyword.get(opts, :execution_policy),
      tool_planner: Keyword.get(opts, :tool_planner),
      budget_policy: budget_policy_from_opts(recipe, opts),
      generation_retry_policy:
        Keyword.get(opts, :generation_retry_policy, LLMRetry.default_policy()),
      generation_fallback_policy: Keyword.get(opts, :generation_fallback_policy),
      tool_retry_policy: Keyword.get(opts, :tool_retry_policy),
      tool_fallback_policy: Keyword.get(opts, :tool_fallback_policy),
      pre_tool_guard: pre_tool_guard_from_opts(opts),
      pre_answer_guard: Keyword.get(opts, :pre_answer_guard),
      stop_pattern: Keyword.get(opts, :stop_pattern),
      continue_when: continue_when_from_opts(workspace, recipe, opts),
      final_pattern: Keyword.get(opts, :final_pattern),
      final_when: Keyword.get(opts, :final_when),
      event_sink: Keyword.get(opts, :event_sink)
    ]
    |> maybe_put_capabilities(capabilities)
  end

  defp resolved_capabilities_from_opts(%Workspace{} = workspace, %Recipe{} = recipe, opts) do
    if CapabilityResolver.requested?(opts) do
      CapabilityResolver.resolve!(workspace,
        agent: Keyword.get(opts, :agent, :standard),
        mode: recipe.mode,
        profile: Keyword.get(opts, :profile),
        toolsets: Keyword.get(opts, :toolsets, []),
        disabled_tools: Keyword.get(opts, :disabled_tools, []),
        tool_config: Keyword.get(opts, :tool_config, %{}),
        approval: Keyword.get(opts, :approval, Keyword.get(opts, :approve)),
        write_policy: Keyword.get(opts, :write_policy),
        command_policy: Keyword.get(opts, :command_policy),
        process_registry: Keyword.get(opts, :process_registry),
        patch_dry_run?: recipe.dry_run?,
        memory_store: Keyword.get(opts, :memory_store),
        memory_store_opts: Keyword.get(opts, :memory_store_opts),
        session_store: Keyword.get(opts, :session_store)
      )
    end
  end

  defp recipe_with_capabilities(%Recipe{} = recipe, %{visible_tools: visible_tools}) do
    %{recipe | visible_tools: visible_tools}
  end

  defp recipe_with_capabilities(%Recipe{} = recipe, _capabilities), do: recipe

  defp maybe_put_capabilities(opts, %{profile: profile, metadata: metadata}) do
    opts
    |> Keyword.put(:capability_profile, profile)
    |> Keyword.update(:state_metadata, %{capability_profile: metadata}, fn existing ->
      Map.put(existing || %{}, :capability_profile, metadata)
    end)
    |> Keyword.update(:metadata, %{capability_profile: metadata}, fn existing ->
      Map.put(existing || %{}, :capability_profile, metadata)
    end)
  end

  defp maybe_put_capabilities(opts, _capabilities), do: opts

  defp continue_when_from_opts(%Workspace{} = workspace, %Recipe{} = recipe, opts) do
    cond do
      Keyword.has_key?(opts, :continue_when) ->
        Keyword.fetch!(opts, :continue_when)

      Keyword.get(opts, :objective_gate?, false) ->
        objective = Keyword.get(opts, :objective, "")

        ObjectiveGate.continue_when(
          workspace,
          objective,
          opts
          |> Keyword.put_new(:max_turns, recipe.max_turns)
          |> Keyword.put_new(:require_changes?, recipe.mode in [:patch, :verify])
        )

      true ->
        nil
    end
  end

  defp budget_policy_from_opts(_recipe, opts) do
    case Keyword.fetch(opts, :budget_policy) do
      {:ok, policy} ->
        policy

      :error ->
        BudgetPolicy.new!(
          max_tool_calls: Keyword.get(opts, :max_tool_calls, 40),
          max_elapsed_ms: Keyword.get(opts, :max_elapsed_ms),
          on_exhaustion: Keyword.get(opts, :on_budget_exhaustion, :review),
          metadata: %{coding_agent_budget?: true}
        )
    end
  end

  defp pre_tool_guard_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :pre_tool_guard) ->
        Keyword.fetch!(opts, :pre_tool_guard)

      Keyword.get(opts, :review_gates?, true) ->
        {ReviewGate, :evaluate, [Keyword.get(opts, :review_gate_opts, [])]}

      true ->
        nil
    end
  end

  defp default_max_turns(:read_only), do: 6
  defp default_max_turns("read_only"), do: 6
  defp default_max_turns(:patch), do: 8
  defp default_max_turns("patch"), do: 8
  defp default_max_turns(_mode), do: 12

  defp state_metadata(%Workspace{} = workspace, %Recipe{} = recipe, opts) do
    opts
    |> Keyword.get(:state_metadata, %{})
    |> Map.merge(%{
      coding_agent?: true,
      workspace_root: workspace.root,
      objective: Keyword.get(opts, :objective),
      objective_gate?: Keyword.get(opts, :objective_gate?, false),
      mode: recipe.mode,
      recipe: recipe.name,
      dry_run?: recipe.dry_run?
    })
  end

  defp turn_metadata(%Workspace{} = workspace, %Recipe{} = recipe, opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> Map.merge(%{
      coding_agent?: true,
      workspace_root: workspace.root,
      mode: recipe.mode,
      recipe: recipe.name,
      visible_tools: recipe.visible_tools
    })
  end

  defp maybe_put_client(integrated_opts, opts) do
    cond do
      Keyword.has_key?(opts, :client) ->
        Keyword.put(integrated_opts, :client, normalize_client(Keyword.fetch!(opts, :client)))

      Keyword.get(opts, :client_backend) == :codex or Keyword.get(opts, :codex?, false) ->
        Keyword.put(integrated_opts, :client, Codex.Client)

      true ->
        integrated_opts
    end
  end

  defp normalize_client(:codex), do: Codex.Client
  defp normalize_client(client), do: client

  defp llm_opts(%Workspace{} = workspace, opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    if codex_client?(opts) do
      llm_opts
      |> Keyword.put_new(:workspace, workspace)
      |> Keyword.put_new(:root, workspace.root)
      |> Keyword.merge(Keyword.get(opts, :codex_opts, []))
    else
      llm_opts
    end
  end

  defp codex_client?(opts) do
    Keyword.get(opts, :client) == :codex or
      Keyword.get(opts, :client) == Codex.Client or
      Keyword.get(opts, :client_backend) == :codex or
      Keyword.get(opts, :codex?, false)
  end

  defp normalize_new_args(workspace_input, opts) do
    cond do
      opts != [] ->
        {workspace_input, opts}

      not is_list(workspace_input) ->
        {workspace_input, opts}

      Keyword.has_key?(workspace_input, :workspace) ->
        workspace = Keyword.fetch!(workspace_input, :workspace)
        {workspace, Keyword.delete(workspace_input, :workspace)}

      Keyword.has_key?(workspace_input, :root) ->
        workspace_keys = [:root, :path_policy, :profile, :persistence]
        workspace = Keyword.take(workspace_input, workspace_keys)
        opts = Keyword.drop(workspace_input, workspace_keys)
        {workspace, opts}

      true ->
        {workspace_input, opts}
    end
  end
end
