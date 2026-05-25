defmodule RunicAI.Agent.ToolExecution do
  @moduledoc """
  Shared execution helper for agent-authored tool leaves.

  Standard agent tool calls already pass through `IntegratedToolAgent`. Assistant
  and RLM workflow nodes can use this module when they need the same registry
  lookup and HITL boundary without adopting the whole conversational loop.
  """

  alias RunicAI.Agent.CapabilityProfile
  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  @spec execute(Registry.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def execute(%Registry{} = registry, tool_name, args, opts \\ [])
      when is_binary(tool_name) and is_map(args) and is_list(opts) do
    profile = Keyword.get(opts, :capability_profile)

    with {:ok, definition} <- Registry.fetch(registry, tool_name),
         :ok <- ensure_visible(definition, profile),
         {:ok, args} <- maybe_review(definition, args, opts) do
      Definition.execute(definition, args)
    end
  end

  @spec requires_review?(Definition.t(), CapabilityProfile.t() | nil) :: boolean()
  def requires_review?(%Definition{} = definition, %CapabilityProfile{} = profile) do
    definition_requires_review?(definition) or CapabilityProfile.gated?(profile, definition.name)
  end

  def requires_review?(%Definition{} = definition, _profile),
    do: definition_requires_review?(definition)

  defp ensure_visible(%Definition{} = definition, %CapabilityProfile{} = profile) do
    if definition.name in profile.visible_tools do
      :ok
    else
      {:error,
       Error.validation("tool is not visible in the active capability profile",
         source: __MODULE__,
         details: %{
           tool_name: definition.name,
           capability_profile: profile.name,
           disabled_tools: profile.disabled_tools,
           visible_tools: profile.visible_tools
         }
       )}
    end
  end

  defp ensure_visible(%Definition{}, _profile), do: :ok

  defp maybe_review(%Definition{} = definition, args, opts) do
    profile = Keyword.get(opts, :capability_profile)

    case {requires_review?(definition, profile), Keyword.get(opts, :review_decider)} do
      {true, decider} when is_function(decider, 2) ->
        request = review_request(definition, args, opts)
        context = Keyword.get(opts, :context, %{})

        case decider.(request, Map.merge(context, %{tool_name: definition.name, params: args})) do
          {:ok, %ReviewDecision{status: :approved}} ->
            {:ok, args}

          {:ok, %ReviewDecision{status: :edited} = decision} ->
            normalize_edit(decision.edited_value, args)

          {:ok, %ReviewDecision{status: status} = decision}
          when status in [:rejected, :cancelled] ->
            {:error,
             Error.validation("tool execution denied by review",
               source: __MODULE__,
               details: %{
                 tool_name: definition.name,
                 resume_key: request.resume_key,
                 decision_status: decision.status
               }
             )}

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, reason} ->
            {:error, Error.from_reason(reason, source: __MODULE__)}
        end

      _other ->
        {:ok, args}
    end
  end

  defp review_request(%Definition{} = definition, args, opts) do
    run_id = Keyword.get(opts, :run_id) || Keyword.get(opts, :session_id)
    toolset = toolset(definition)

    ReviewRequest.new!(:tool_execution,
      checkpoint: :pre_tool,
      resume_key:
        "review:tool:#{run_id || System.unique_integer([:positive])}:#{definition.name}:#{System.unique_integer([:positive])}",
      options: [:approve, :reject, :edit, :cancel],
      subject: %{tool_name: definition.name, arguments: args},
      details: %{
        tool_name: definition.name,
        arguments: args,
        toolset: toolset,
        reason: :gated_tool,
        capability_profile:
          opts
          |> Keyword.get(:capability_profile)
          |> CapabilityProfile.snapshot()
      },
      metadata: %{
        safe?: false,
        risk: :medium,
        tool_name: definition.name,
        toolset: toolset,
        requires_review?: true
      }
    )
  end

  defp normalize_edit(%{"arguments" => arguments}, _args) when is_map(arguments),
    do: {:ok, arguments}

  defp normalize_edit(%{arguments: arguments}, _args) when is_map(arguments), do: {:ok, arguments}
  defp normalize_edit(arguments, _args) when is_map(arguments), do: {:ok, arguments}

  defp normalize_edit(text, _args) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, arguments} when is_map(arguments) ->
        {:ok, arguments}

      _other ->
        {:error,
         Error.validation("tool review rewrite must be a JSON object or map",
           source: __MODULE__,
           details: %{edited_value: text}
         )}
    end
  end

  defp normalize_edit(_edited, args), do: {:ok, args}

  defp definition_requires_review?(%Definition{} = definition) do
    metadata = definition.metadata || %{}
    policy_metadata = (definition.execution_policy && definition.execution_policy.metadata) || %{}

    metadata[:requires_review?] == true or metadata["requires_review?"] == true or
      policy_metadata[:requires_review?] == true or policy_metadata["requires_review?"] == true
  end

  defp toolset(%Definition{} = definition) do
    metadata = definition.metadata || %{}
    Map.get(metadata, :toolset, Map.get(metadata, "toolset"))
  end
end
