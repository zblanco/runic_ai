defmodule RunicSandbox.ConsumerProfiles do
  @moduledoc """
  Example consumer profiles for systems that want to configure RunicSandbox
  without depending on RunicAI product modules.
  """

  @default_image "runic-ai/sandbox:elixir-python-node"

  @spec libbit_workspace(keyword()) :: {atom(), keyword()}
  def libbit_workspace(opts \\ []) do
    workspace_id = required_string!(opts, :workspace_id)
    tenant_id = Keyword.get(opts, :tenant_id)
    name = Keyword.get(opts, :name, :libbit_workspace)
    backend = Keyword.get(opts, :backend, :sprites)
    network = Keyword.get(opts, :network, :restricted)
    workspace_ref = safe_ref(workspace_id, tenant_id)

    {name,
     [
       backend: backend,
       runtimes: Keyword.get(opts, :runtimes, [:bash, :python, :node, :elixir]),
       network: network,
       stateful?: true,
       workspace: [
         mode: Keyword.get(opts, :workspace_mode, :copy_in),
         mount: Keyword.get(opts, :workspace_mount, "/workspace"),
         persist?: true,
         metadata: %{
           consumer: :libbit,
           workspace_id: workspace_id,
           workspace_ref: workspace_ref
         }
       ],
       pool: [
         warm: Keyword.get(opts, :warm, 1),
         max: Keyword.get(opts, :max, 4),
         idle_ttl_ms: Keyword.get(opts, :idle_ttl_ms, 300_000),
         checkout_timeout_ms: Keyword.get(opts, :checkout_timeout_ms, 5_000),
         reset_on_checkin?: Keyword.get(opts, :reset_on_checkin?, false),
         checkpoint_on_checkout?: Keyword.get(opts, :checkpoint_on_checkout?, true),
         backend_affinity: Keyword.get(opts, :backend_affinity, :profile)
       ],
       policy: [
         network: network,
         persist_changes?: true,
         metadata: %{
           checkpoint_on_risky_action?: Keyword.get(opts, :checkpoint_on_risky_action?, true)
         }
       ],
       backend_options: backend_options(backend, opts, workspace_ref),
       metadata: %{
         consumer: :libbit,
         workspace_id: workspace_id,
         tenant_id: tenant_id,
         workflow_run_id: Keyword.get(opts, :workflow_run_id),
         agent_id: Keyword.get(opts, :agent_id),
         actor_id: Keyword.get(opts, :actor_id),
         integration_status: :example_only
       }
     ]}
  end

  defp backend_options(:sprites, opts, workspace_ref) do
    %{
      sprite: Keyword.get(opts, :sprite, "libbit-#{workspace_ref}"),
      create_policy: Keyword.get(opts, :create_policy, :create_if_missing),
      organization: Keyword.get(opts, :organization),
      token_env: Keyword.get(opts, :token_env, "SPRITES_TOKEN")
    }
    |> reject_nil_values()
  end

  defp backend_options(:docker, opts, _workspace_ref) do
    %{
      image: Keyword.get(opts, :image, @default_image)
    }
  end

  defp backend_options(_backend, opts, _workspace_ref) do
    opts
    |> Keyword.get(:backend_options, %{})
    |> Map.new()
  end

  defp required_string!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      _other ->
        raise ArgumentError, "#{key} is required and must be a non-empty string"
    end
  end

  defp safe_ref(workspace_id, tenant_id) do
    slug =
      workspace_id
      |> slug()
      |> String.slice(0, 40)

    hash =
      [tenant_id, workspace_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(<<0>>)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "#{slug}-#{hash}"
  end

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      ref -> ref
    end
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
