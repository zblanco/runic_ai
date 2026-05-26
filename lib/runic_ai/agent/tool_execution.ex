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

    details =
      Map.merge(
        %{
          tool_name: definition.name,
          arguments: args,
          toolset: toolset,
          reason: :gated_tool,
          capability_profile:
            opts
            |> Keyword.get(:capability_profile)
            |> CapabilityProfile.snapshot()
        },
        tool_review_details(definition, args)
      )

    ReviewRequest.new!(:tool_execution,
      checkpoint: :pre_tool,
      resume_key:
        "review:tool:#{run_id || System.unique_integer([:positive])}:#{definition.name}:#{System.unique_integer([:positive])}",
      options: [:approve, :reject, :edit, :cancel],
      subject: %{tool_name: definition.name, arguments: args},
      details: details,
      metadata: %{
        safe?: false,
        risk: :medium,
        tool_name: definition.name,
        toolset: toolset,
        requires_review?: true
      }
    )
  end

  defp tool_review_details(%Definition{name: "execute_code"} = definition, args)
       when is_map(args) do
    source = arg(args, :code, arg(args, :source, ""))
    files = arg(args, :files, %{})

    %{
      sandbox: arg(args, :sandbox, :local_code),
      runtime: arg(args, :runtime, :bash),
      network: normalize_sandbox_network(arg(args, :network, :disabled)),
      timeout_ms: arg(args, :timeout_ms, nil),
      max_output_bytes: arg(args, :max_output_bytes, nil),
      code_bytes: byte_size(to_string(source)),
      code_preview: source |> to_string() |> String.slice(0, 1_000),
      input_files: input_file_summaries(files),
      sandbox_capability:
        Map.take(definition.metadata, [
          :sandbox_backend,
          :isolation_level,
          :sandbox,
          :runtimes,
          :network,
          :state_model,
          :transport_model,
          :session,
          :checkpoint_policy,
          :service_policy
        ])
    }
  end

  defp tool_review_details(%Definition{name: name} = definition, args)
       when name in [
              "open_sandbox_session",
              "sandbox_exec",
              "sandbox_write_file",
              "checkpoint_sandbox",
              "restore_sandbox",
              "start_sandbox_service",
              "stop_sandbox_service",
              "open_sandbox_proxy"
            ] and is_map(args) do
    source = arg(args, :code, arg(args, :source, ""))

    %{
      sandbox_operation: name,
      sandbox: arg(args, :sandbox, :local_code),
      session_id: arg(args, :session_id, arg(args, :id, nil)),
      runtime: arg(args, :runtime, nil),
      network: normalize_sandbox_network(arg(args, :network, :disabled)),
      path: arg(args, :path, nil),
      service_id: arg(args, :service_id, nil),
      checkpoint_ref: arg(args, :checkpoint_ref, nil),
      code_bytes: byte_size(to_string(source)),
      code_preview: source |> to_string() |> String.slice(0, 1_000),
      sandbox_capability: sandbox_capability(definition)
    }
  end

  defp tool_review_details(%Definition{}, _args), do: %{}

  defp sandbox_capability(%Definition{} = definition) do
    Map.take(definition.metadata, [
      :sandbox_backend,
      :isolation_level,
      :sandbox,
      :runtimes,
      :network,
      :state_model,
      :transport_model,
      :session,
      :checkpoint_policy,
      :service_policy
    ])
  end

  defp normalize_sandbox_network(value) when value in [:disabled, :host, :restricted], do: value
  defp normalize_sandbox_network("disabled"), do: :disabled
  defp normalize_sandbox_network("host"), do: :host
  defp normalize_sandbox_network("restricted"), do: :restricted
  defp normalize_sandbox_network(%{enabled: false}), do: :disabled
  defp normalize_sandbox_network(%{"enabled" => false}), do: :disabled
  defp normalize_sandbox_network(%{enabled: true}), do: :host
  defp normalize_sandbox_network(%{"enabled" => true}), do: :host
  defp normalize_sandbox_network(_value), do: :disabled

  defp input_file_summaries(files) when is_map(files) do
    files
    |> Enum.map(fn {path, content} ->
      %{path: to_string(path), bytes: byte_size(to_string(content))}
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp input_file_summaries(_files), do: []

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

  defp arg(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
