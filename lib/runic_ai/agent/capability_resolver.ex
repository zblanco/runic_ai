defmodule RunicAI.Agent.CapabilityResolver do
  @moduledoc """
  Resolves named capability profiles into a tool registry and visible tool list.

  This module does not execute tools. It classifies existing tool definitions by
  toolset, applies runtime profile configuration, and records which visible
  tools are gated by review.
  """

  alias RunicAI.Agent.CapabilityProfile
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.Tool.Registry

  @known_toolsets [
    :file,
    :git,
    :patch,
    :terminal,
    :process,
    :profile,
    :verify,
    :code_execution,
    :computing,
    :web,
    :browser,
    :media,
    :memory,
    :session_search,
    :delegation,
    :clarify,
    :todo
  ]

  @preset_toolsets %{
    safe: [:file, :memory, :media],
    coding_read: [:file, :git, :memory],
    coding_patch: [:file, :git, :patch, :memory],
    coding_verify: [:file, :git, :patch, :profile, :verify, :process, :memory],
    local_workbench: [
      :file,
      :git,
      :patch,
      :terminal,
      :process,
      :profile,
      :verify,
      :code_execution,
      :computing,
      :memory,
      :session_search,
      :clarify
    ],
    research: [:web, :browser, :media, :memory, :session_search, :file, :clarify],
    full_local: [
      :file,
      :git,
      :patch,
      :terminal,
      :process,
      :profile,
      :verify,
      :code_execution,
      :computing,
      :web,
      :browser,
      :media,
      :memory,
      :session_search,
      :delegation,
      :clarify,
      :todo
    ]
  }

  @mode_presets %{
    read_only: :coding_read,
    patch: :coding_patch,
    verify: :coding_verify
  }

  @future_toolsets [
    :computing,
    :web,
    :browser,
    :media,
    :memory,
    :session_search,
    :delegation,
    :clarify,
    :todo
  ]

  @type resolved :: %{
          required(:profile) => CapabilityProfile.t(),
          required(:registry) => Registry.t(),
          required(:visible_tools) => [String.t()],
          required(:gated_tools) => [String.t()],
          required(:command_policy) => CommandPolicy.t(),
          required(:metadata) => map()
        }

  @spec known_toolsets() :: [atom()]
  def known_toolsets, do: @known_toolsets

  @spec local_workbench_profile?(term()) :: boolean()
  def local_workbench_profile?(profile),
    do: normalize_profile_name(profile) == {:ok, :local_workbench}

  @spec requested?(keyword()) :: boolean()
  def requested?(opts) when is_list(opts) do
    Enum.any?([:capability_profile, :profile, :toolsets, :disabled_tools, :tool_config], fn key ->
      case Keyword.get(opts, key) do
        nil -> false
        [] -> false
        "" -> false
        %{} = map when map_size(map) == 0 -> false
        _value -> true
      end
    end)
  end

  @spec resolve(Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          {:ok, resolved()} | {:error, Error.t()}
  def resolve(workspace_input, opts \\ []) when is_list(opts) do
    with {:ok, workspace} <- Workspace.from_input(workspace_input),
         {:ok, mode} <- normalize_mode(Keyword.get(opts, :mode, :verify)),
         {:ok, preset} <- resolve_preset(mode, opts),
         {:ok, configured_toolsets} <- configured_toolsets(preset, opts),
         {:ok, disabled_tools} <- normalize_tool_names(Keyword.get(opts, :disabled_tools, [])),
         {:ok, command_policy} <- command_policy(preset, configured_toolsets, opts),
         registry <- coding_registry(workspace, command_policy, opts),
         tools_by_toolset <- tools_by_toolset(registry),
         {:ok, disabled_available_tools} <- validate_disabled_tools(disabled_tools, registry),
         visible_tools <- visible_tools(registry, configured_toolsets, disabled_available_tools),
         gated_tools <- gated_tools(registry, visible_tools),
         profile <-
           profile(
             opts,
             mode,
             preset,
             configured_toolsets,
             visible_tools,
             gated_tools,
             disabled_tools,
             disabled_available_tools,
             tools_by_toolset
           ) do
      metadata = CapabilityProfile.snapshot(profile)

      {:ok,
       %{
         profile: profile,
         registry: registry,
         visible_tools: visible_tools,
         gated_tools: gated_tools,
         command_policy: command_policy,
         metadata: metadata
       }}
    end
  end

  @spec resolve!(Workspace.t() | keyword() | map() | Path.t(), keyword()) :: resolved()
  def resolve!(workspace_input, opts \\ []) do
    case resolve(workspace_input, opts) do
      {:ok, resolved} -> resolved
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  @spec snapshot_for_launch(Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          map() | nil
  def snapshot_for_launch(workspace_input, opts \\ []) do
    case resolve(workspace_input, opts) do
      {:ok, %{metadata: metadata}} -> metadata
      {:error, _error} -> nil
    end
  end

  @spec enabled_toolsets(keyword()) :: [atom()]
  def enabled_toolsets(opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :verify)

    with {:ok, mode} <- normalize_mode(mode),
         {:ok, preset} <- resolve_preset(mode, opts),
         {:ok, toolsets} <- configured_toolsets(preset, opts) do
      toolsets
    else
      _error -> []
    end
  end

  @spec visible_tool_names_for_profile(keyword()) :: [String.t()]
  def visible_tool_names_for_profile(opts) when is_list(opts) do
    toolsets = enabled_toolsets(opts)
    disabled_tools = static_disabled_tool_names(Keyword.get(opts, :disabled_tools, []))

    static_tools_by_toolset()
    |> Enum.filter(fn {toolset, _tools} -> toolset in toolsets end)
    |> Enum.flat_map(fn {_toolset, tools} -> tools end)
    |> Enum.reject(&(&1 in disabled_tools))
    |> Enum.uniq()
  end

  defp resolve_preset(mode, opts) do
    case Keyword.fetch(opts, :profile) do
      {:ok, profile} when profile not in [nil, ""] ->
        normalize_profile_name(profile)

      _other ->
        {:ok, Map.fetch!(@mode_presets, mode)}
    end
  end

  defp configured_toolsets(preset, opts) do
    explicit = Keyword.get(opts, :toolsets, [])

    with {:ok, explicit_toolsets} <- normalize_toolsets(explicit) do
      toolsets =
        if explicit_toolsets == [] do
          Map.fetch!(@preset_toolsets, preset)
        else
          Map.fetch!(@preset_toolsets, preset) ++ explicit_toolsets
        end

      {:ok, Enum.uniq(toolsets)}
    end
  end

  defp coding_registry(%Workspace{} = workspace, %CommandPolicy{} = command_policy, opts) do
    Tools.default_registry(workspace,
      command_policy: command_policy,
      process_registry: Keyword.get(opts, :process_registry),
      patch_dry_run?: Keyword.get(opts, :patch_dry_run?, false),
      memory_store: Keyword.get(opts, :memory_store),
      memory_store_opts: Keyword.get(opts, :memory_store_opts, namespace: workspace.root),
      session_store: Keyword.get(opts, :session_store),
      web_opts: Keyword.get(opts, :web_opts, web_opts(opts)),
      media_opts: Keyword.get(opts, :media_opts, media_opts(opts)),
      browser_opts: Keyword.get(opts, :browser_opts, browser_opts(opts)),
      delegate_opts: Keyword.get(opts, :delegate_opts, delegate_opts(opts))
    )
  end

  defp command_policy(preset, toolsets, opts) do
    case Keyword.get(opts, :command_policy) do
      nil ->
        {:ok, default_command_policy(preset, toolsets, opts)}

      input ->
        CommandPolicy.from_input(input)
    end
  end

  defp default_command_policy(preset, _toolsets, opts)
       when preset in [:local_workbench, :full_local] do
    CommandPolicy.new!(
      allowed_commands: nil,
      allow_shell: true,
      allow_just_bash: true,
      timeout_ms: terminal_timeout(opts, 120_000),
      max_output_bytes: terminal_output_cap(opts, 65_536),
      metadata: %{
        capability_profile: preset,
        local_workbench?: preset == :local_workbench,
        review_default: :unsafe_actions
      }
    )
  end

  defp default_command_policy(_preset, toolsets, opts) do
    if :terminal in toolsets do
      CommandPolicy.new!(
        allowed_commands: nil,
        allow_shell: true,
        allow_just_bash: true,
        timeout_ms: terminal_timeout(opts, 120_000),
        max_output_bytes: terminal_output_cap(opts, 65_536),
        metadata: %{
          capability_profile: :custom_terminal,
          review_default: :unsafe_actions
        }
      )
    else
      default_mode_command_policy(opts)
    end
  end

  defp default_mode_command_policy(opts) do
    mode = Keyword.get(opts, :mode, :verify)

    CommandPolicy.new!(
      allowed_commands:
        if(normalize_mode_value(mode) == :verify, do: ["git", "mix"], else: ["git"]),
      allow_shell: false,
      allow_just_bash: false,
      timeout_ms: terminal_timeout(opts, 30_000),
      max_output_bytes: terminal_output_cap(opts, 32_768),
      metadata: %{coding_agent_mode: normalize_mode_value(mode)}
    )
  end

  defp terminal_timeout(opts, default) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:terminal, :timeout_ms])
    |> case do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _other -> default
        end

      _other ->
        default
    end
  end

  defp terminal_output_cap(opts, default) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:terminal, :max_output_bytes])
    |> case do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _other -> default
        end

      _other ->
        default
    end
  end

  defp web_opts(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:web])
    |> case do
      config when is_map(config) ->
        [
          provider:
            Map.get(
              config,
              :provider_module,
              Map.get(config, "provider_module", RunicAI.Web.Providers.Static)
            ),
          provider_opts: Map.get(config, :provider_opts, Map.get(config, "provider_opts", []))
        ]

      _other ->
        []
    end
  end

  defp media_opts(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:media])
    |> case do
      config when is_map(config) ->
        [
          client: Map.get(config, :client, Map.get(config, "client")),
          model: Map.get(config, :model, Map.get(config, "model"))
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      _other ->
        []
    end
  end

  defp browser_opts(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:browser])
    |> case do
      config when is_map(config) ->
        [
          session: Map.get(config, :session, Map.get(config, "session")),
          backend: browser_backend(Map.get(config, :backend, Map.get(config, "backend"))),
          backend_opts: Map.get(config, :backend_opts, Map.get(config, "backend_opts", [])),
          inactivity_timeout_ms:
            Map.get(config, :inactivity_timeout_ms, Map.get(config, "inactivity_timeout_ms"))
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      _other ->
        []
    end
  end

  defp delegate_opts(opts) do
    opts
    |> Keyword.get(:tool_config, %{})
    |> get_in_config([:delegation])
    |> case do
      config when is_map(config) ->
        [
          runner: Map.get(config, :runner, Map.get(config, "runner")),
          delegate_fun: Map.get(config, :delegate_fun, Map.get(config, "delegate_fun"))
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      _other ->
        []
    end
  end

  defp browser_backend(nil), do: nil
  defp browser_backend(:agent_browser), do: RunicAI.Browser.Backends.AgentBrowser
  defp browser_backend("agent_browser"), do: RunicAI.Browser.Backends.AgentBrowser
  defp browser_backend(:fake), do: RunicAI.Browser.Backends.Fake
  defp browser_backend("fake"), do: RunicAI.Browser.Backends.Fake
  defp browser_backend(module) when is_atom(module), do: module

  defp profile(
         opts,
         mode,
         preset,
         toolsets,
         visible_tools,
         gated_tools,
         disabled_tools,
         disabled_available_tools,
         tools_by_toolset
       ) do
    %CapabilityProfile{
      name: preset,
      agent: normalize_agent(Keyword.get(opts, :agent, :standard)),
      mode: mode,
      preset: preset,
      toolsets: toolsets,
      visible_tools: visible_tools,
      gated_tools: gated_tools,
      disabled_tools: disabled_tools,
      disabled_available_tools: disabled_available_tools,
      config: config(toolsets, opts),
      policy: policy(opts),
      tools_by_toolset: tools_by_toolset,
      toolsets_by_tool:
        tools_by_toolset
        |> Enum.flat_map(fn {toolset, names} -> Enum.map(names, &{&1, toolset}) end)
        |> Map.new(),
      metadata: %{
        resolver: __MODULE__,
        resolved_at: DateTime.utc_now(),
        future_toolsets: Enum.filter(toolsets, &(&1 in @future_toolsets))
      }
    }
  end

  defp config(toolsets, opts) do
    configured = Keyword.get(opts, :tool_config, %{})

    %{
      terminal: %{
        backend: :local_argv,
        shell?: :terminal in toolsets,
        shell_review: :always,
        timeout_ms: terminal_timeout(opts, 120_000)
      },
      code_execution: %{
        backends: [:just_bash],
        runtimes: [:bash],
        isolation_level: :in_process_virtual,
        review: :unsafe_actions
      },
      computing: %{components: [:enum, :stream, :string, :json, :file, :calendar, :io]},
      web: %{
        provider: :static,
        max_results: 5,
        persist_sources?: true
      },
      browser: %{
        backend: :agent_browser,
        fallback_backend: :fake,
        inactivity_timeout_ms: 120_000,
        domain_policy: %{allowed_domains: [], blocked_domains: []},
        recording: %{screenshots: false, video: false, console: true}
      },
      media: %{
        image_model: "openai:gpt-image-1",
        vision_model: "openai:gpt-4o-mini",
        speech_model: "openai:tts-1",
        transcription_model: "openai:whisper-1",
        persist_outputs?: true
      },
      memory: %{
        store: :local_ets,
        explicit_write_review: :always,
        session_search?: :session_search in toolsets
      },
      delegation: %{
        default_child_profile: :coding_read,
        persist_subagent_runs?: true,
        inject_intermediate_events?: false
      }
    }
    |> deep_merge(configured)
  end

  defp policy(opts) do
    %{
      approval: Keyword.get(opts, :approval, Keyword.get(opts, :approve, :ask)),
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      network: :disabled_by_default
    }
  end

  defp tools_by_toolset(%Registry{tools: tools}) do
    tools
    |> Enum.group_by(&toolset_for_tool/1, & &1.name)
    |> Map.new(fn {toolset, names} -> {toolset, Enum.sort(names)} end)
  end

  defp visible_tools(%Registry{tools: tools}, toolsets, disabled_tools) do
    tools
    |> Enum.filter(fn tool -> toolset_for_tool(tool) in toolsets end)
    |> Enum.reject(fn tool -> tool.name in disabled_tools end)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  defp gated_tools(%Registry{tools: tools}, visible_tools) do
    tools
    |> Enum.filter(fn tool -> tool.name in visible_tools and gated_tool?(tool) end)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  defp gated_tool?(tool) do
    metadata = tool.metadata || %{}
    policy_metadata = (tool.execution_policy && tool.execution_policy.metadata) || %{}

    metadata[:requires_review?] == true or metadata["requires_review?"] == true or
      policy_metadata[:requires_review?] == true or policy_metadata["requires_review?"] == true
  end

  defp validate_disabled_tools(disabled_tools, %Registry{} = registry) do
    available = Registry.names(registry)
    unknown = Enum.reject(disabled_tools, &(&1 in available))

    case unknown do
      [] ->
        {:ok, disabled_tools}

      _unknown ->
        {:error,
         Error.validation("capability profile disabled unknown tools",
           source: __MODULE__,
           details: %{unknown_tools: unknown, available_tools: available}
         )}
    end
  end

  defp toolset_for_tool(tool) do
    metadata = tool.metadata || %{}
    Map.get(metadata, :toolset, Map.get(metadata, "toolset", fallback_toolset(tool.name)))
  end

  defp fallback_toolset(name) do
    cond do
      name in Recipe.read_tools() ->
        :file

      name in Recipe.git_read_tools() ->
        :git

      name in Recipe.patch_tools() ->
        :patch

      name in Recipe.verification_tools() ->
        :profile

      String.starts_with?(name, "process_") or name == "start_process" ->
        :process

      name in ["run_command"] ->
        :terminal

      name in ["execute_code", "sandbox_status"] ->
        :code_execution

      name in ["memory_write", "memory_recall"] ->
        :memory

      name in ["session_search"] ->
        :session_search

      name in ["web_search", "web_extract"] ->
        :web

      name in [
        "vision_analyze",
        "image_generate",
        "speech_generate",
        "transcribe_audio",
        "ocr_document"
      ] ->
        :media

      String.starts_with?(name, "browser_") ->
        :browser

      name in ["delegate_task"] ->
        :delegation

      name in ["clarify"] ->
        :clarify

      true ->
        :unknown
    end
  end

  defp static_tools_by_toolset do
    %{
      file: Recipe.read_tools(),
      git: Recipe.git_read_tools(),
      patch: Recipe.patch_tools(),
      terminal: ["run_command"],
      profile: [
        "compile_project",
        "run_tests",
        "run_formatter",
        "run_linter",
        "project_command",
        "runtime_smoke"
      ],
      verify: ["source_assert", "changed_file_inventory"],
      process: ["start_process", "process_poll", "process_log", "process_write", "process_kill"],
      code_execution: ["execute_code", "sandbox_status"],
      memory: ["memory_write", "memory_recall"],
      session_search: ["session_search"],
      web: ["web_search", "web_extract"],
      media: [
        "vision_analyze",
        "image_generate",
        "speech_generate",
        "transcribe_audio",
        "ocr_document"
      ],
      browser: [
        "browser_navigate",
        "browser_snapshot",
        "browser_click",
        "browser_type",
        "browser_press",
        "browser_scroll",
        "browser_console",
        "browser_screenshot",
        "browser_vision"
      ],
      delegation: ["delegate_task"],
      clarify: ["clarify"]
    }
  end

  defp normalize_profile_name(profile) when is_atom(profile) do
    if Map.has_key?(@preset_toolsets, profile) do
      {:ok, profile}
    else
      invalid_profile(profile)
    end
  end

  defp normalize_profile_name(profile) when is_binary(profile) do
    normalized = profile |> String.downcase() |> String.replace("-", "_")

    @preset_toolsets
    |> Map.keys()
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> invalid_profile(profile)
      profile -> {:ok, profile}
    end
  end

  defp normalize_profile_name(profile), do: invalid_profile(profile)

  defp invalid_profile(profile) do
    {:error,
     Error.validation("unknown capability profile",
       source: __MODULE__,
       details: %{profile: profile, valid_profiles: Map.keys(@preset_toolsets)}
     )}
  end

  defp normalize_toolsets(nil), do: {:ok, []}
  defp normalize_toolsets(""), do: {:ok, []}

  defp normalize_toolsets(toolsets) when is_binary(toolsets) do
    toolsets
    |> split_csv()
    |> normalize_toolsets()
  end

  defp normalize_toolsets(toolsets) when is_list(toolsets) do
    toolsets
    |> Enum.reduce_while({:ok, []}, fn toolset, {:ok, acc} ->
      case normalize_toolset(toolset) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_toolsets(toolset), do: normalize_toolsets([toolset])

  defp normalize_toolset(toolset) when is_atom(toolset) and toolset in @known_toolsets,
    do: {:ok, toolset}

  defp normalize_toolset(toolset) when is_atom(toolset), do: invalid_toolset(toolset)

  defp normalize_toolset(toolset) when is_binary(toolset) do
    normalized =
      toolset
      |> String.downcase()
      |> String.replace("-", "_")
      |> String.split(":", parts: 2)
      |> hd()

    @known_toolsets
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> invalid_toolset(toolset)
      toolset -> {:ok, toolset}
    end
  end

  defp normalize_toolset(toolset), do: invalid_toolset(toolset)

  defp invalid_toolset(toolset) do
    {:error,
     Error.validation("unknown capability toolset",
       source: __MODULE__,
       details: %{toolset: toolset, valid_toolsets: @known_toolsets}
     )}
  end

  defp normalize_tool_names(nil), do: {:ok, []}
  defp normalize_tool_names(""), do: {:ok, []}

  defp normalize_tool_names(value) when is_binary(value) do
    value |> split_csv() |> normalize_tool_names()
  end

  defp normalize_tool_names(values) when is_list(values) do
    {:ok,
     values
     |> Enum.flat_map(fn
       value when is_binary(value) -> split_csv(value)
       value -> [to_string(value)]
     end)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_tool_names(value), do: normalize_tool_names([value])

  defp static_disabled_tool_names(nil), do: []
  defp static_disabled_tool_names(""), do: []

  defp static_disabled_tool_names(value) when is_binary(value), do: split_csv(value)

  defp static_disabled_tool_names(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) -> split_csv(value)
      value -> [to_string(value)]
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp static_disabled_tool_names(value), do: static_disabled_tool_names([value])

  defp split_csv(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_mode(mode) do
    case normalize_mode_value(mode) do
      mode when mode in [:read_only, :patch, :verify] ->
        {:ok, mode}

      other ->
        {:error,
         Error.validation("invalid capability mode", source: __MODULE__, details: %{mode: other})}
    end
  end

  defp normalize_mode_value(mode) when mode in [:read_only, :patch, :verify], do: mode
  defp normalize_mode_value("read-only"), do: :read_only
  defp normalize_mode_value("read_only"), do: :read_only
  defp normalize_mode_value("patch"), do: :patch
  defp normalize_mode_value("verify"), do: :verify
  defp normalize_mode_value(_mode), do: :verify

  defp normalize_agent(agent) when agent in [:standard, :assistant, :rlm], do: agent
  defp normalize_agent("standard"), do: :standard
  defp normalize_agent("assistant"), do: :assistant
  defp normalize_agent("rlm"), do: :rlm
  defp normalize_agent(_agent), do: :standard

  defp get_in_config(config, keys) do
    Enum.reduce(keys, config, fn
      key, map when is_map(map) -> Map.get(map, key, Map.get(map, Atom.to_string(key)))
      _key, _other -> nil
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
