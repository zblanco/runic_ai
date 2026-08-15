defmodule RunicAI.Agent.CapabilityProfile do
  @moduledoc """
  Resolved model-visible capability profile for one agent run.

  The profile is intentionally data-only. Tool execution still goes through
  `RunicAI.Tool.Definition`, the shared coding tools, and normal review policy.
  """

  @enforce_keys [
    :name,
    :agent,
    :mode,
    :toolsets,
    :visible_tools,
    :gated_tools,
    :disabled_tools,
    :disabled_available_tools,
    :config,
    :policy,
    :tools_by_toolset,
    :toolsets_by_tool,
    :metadata
  ]
  defstruct [
    :name,
    :agent,
    :mode,
    :preset,
    toolsets: [],
    visible_tools: [],
    gated_tools: [],
    disabled_tools: [],
    disabled_available_tools: [],
    config: %{},
    policy: %{},
    tools_by_toolset: %{},
    toolsets_by_tool: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          name: atom(),
          agent: atom(),
          mode: atom(),
          preset: atom() | nil,
          toolsets: [atom()],
          visible_tools: [String.t()],
          gated_tools: [String.t()],
          disabled_tools: [String.t()],
          disabled_available_tools: [String.t()],
          config: map(),
          policy: map(),
          tools_by_toolset: %{optional(atom()) => [String.t()]},
          toolsets_by_tool: %{optional(String.t()) => atom()},
          metadata: map()
        }

  @spec snapshot(t() | nil) :: map() | nil
  def snapshot(nil), do: nil

  def snapshot(%__MODULE__{} = profile) do
    %{
      name: profile.name,
      agent: profile.agent,
      mode: profile.mode,
      preset: profile.preset,
      toolsets: profile.toolsets,
      visible_tools: profile.visible_tools,
      gated_tools: profile.gated_tools,
      disabled_tools: profile.disabled_tools,
      disabled_available_tools: profile.disabled_available_tools,
      config: profile.config,
      policy: profile.policy,
      tools_by_toolset: profile.tools_by_toolset,
      toolsets_by_tool: profile.toolsets_by_tool,
      metadata: profile.metadata
    }
  end

  @spec gated?(t() | nil, String.t()) :: boolean()
  def gated?(%__MODULE__{gated_tools: gated_tools}, tool_name) when is_binary(tool_name),
    do: tool_name in gated_tools

  def gated?(_profile, _tool_name), do: false

  @spec toolset_enabled?(t() | nil, atom()) :: boolean()
  def toolset_enabled?(%__MODULE__{toolsets: toolsets}, toolset) when is_atom(toolset),
    do: toolset in toolsets

  def toolset_enabled?(_profile, _toolset), do: false
end
