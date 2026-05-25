defmodule RunicAI.Agent.ModelClientResolver do
  @moduledoc """
  Shared preflight resolver for agent model/client launch configuration.

  The resolver is intentionally conservative. ReqLLM-backed launches can pass
  provider model names through. Local Codex CLI launches use the account-backed
  Codex default when the requested model is blank/default/legacy Runic default,
  and reject provider-prefixed model strings before a session starts.
  """

  alias RunicAI.Coding.Codex.Client, as: CodexClient
  alias RunicAI.Error

  @legacy_runic_default "openai:gpt-5.4-mini"
  @codex_default_label "codex-account-default"
  @codex_client_label "codex"
  @provider_prefixes ["openai:", "anthropic:", "google:", "groq:", "mistral:"]

  @type decision :: %{
          requested_model: String.t() | nil,
          resolved_model: String.t() | nil,
          effective_model: String.t(),
          provider: String.t(),
          client_label: String.t(),
          account_mode: String.t() | nil,
          decision: String.t(),
          reason: String.t(),
          warnings: [String.t()]
        }

  @spec resolve(keyword()) :: {:ok, keyword(), decision()} | {:error, Error.t()}
  def resolve(opts) when is_list(opts) do
    requested_model = normalize_model(Keyword.get(opts, :model))
    client = Keyword.get(opts, :client)
    client_label = normalize_client_label(Keyword.get(opts, :client_label), client)

    if codex_client?(client_label, client) do
      resolve_codex(opts, requested_model, client_label)
    else
      resolve_default(opts, requested_model, client_label)
    end
  end

  @spec normalize_codex_model(String.t() | nil) ::
          {:ok, String.t() | nil, decision()} | {:error, Error.t()}
  def normalize_codex_model(model) do
    case resolve(model: model, client: CodexClient, client_label: @codex_client_label) do
      {:ok, resolved, decision} -> {:ok, Keyword.get(resolved, :model), decision}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp resolve_codex(opts, requested_model, client_label) do
    cond do
      codex_default_model?(requested_model) ->
        resolved = opts |> Keyword.put(:model, nil) |> Keyword.put(:client_label, client_label)

        {:ok, resolved,
         decision(
           requested_model,
           nil,
           @codex_default_label,
           "codex_cli",
           client_label,
           "local_codex_cli",
           "codex_account_default",
           "blank/default/legacy Runic model delegates to the local Codex account default",
           legacy_warning(requested_model)
         )}

      provider_prefixed?(requested_model) ->
        {:error,
         Error.validation("unsupported model for local Codex client",
           source: __MODULE__,
           details: %{
             client: client_label,
             requested_model: requested_model,
             reason: "provider-prefixed models are not passed to codex exec",
             supported: [@codex_default_label, "unprefixed Codex CLI model ids"]
           }
         )}

      true ->
        resolved =
          opts
          |> Keyword.put(:model, requested_model)
          |> Keyword.put(:client_label, client_label)

        {:ok, resolved,
         decision(
           requested_model,
           requested_model,
           requested_model,
           "codex_cli",
           client_label,
           "local_codex_cli",
           "explicit_codex_model",
           "using explicit unprefixed Codex CLI model id",
           []
         )}
    end
  end

  defp resolve_default(opts, requested_model, client_label) do
    resolved =
      opts
      |> Keyword.put(:model, requested_model)
      |> Keyword.put(:client_label, client_label)

    effective_model =
      case requested_model do
        nil -> "default"
        model -> model
      end

    {:ok, resolved,
     decision(
       requested_model,
       requested_model,
       effective_model,
       "req_llm",
       client_label,
       nil,
       "provider_passthrough",
       "non-Codex client keeps provider model resolution with ReqLLM or injected client",
       []
     )}
  end

  defp codex_default_model?(model), do: model in [nil, "", "default", @legacy_runic_default]

  defp provider_prefixed?(model) when is_binary(model) do
    Enum.any?(@provider_prefixes, &String.starts_with?(model, &1))
  end

  defp provider_prefixed?(_model), do: false

  defp normalize_model(nil), do: nil
  defp normalize_model(model) when is_binary(model), do: String.trim(model)
  defp normalize_model(model), do: to_string(model)

  defp normalize_client_label(nil, CodexClient), do: @codex_client_label
  defp normalize_client_label(nil, _client), do: "default"
  defp normalize_client_label("", client), do: normalize_client_label(nil, client)
  defp normalize_client_label(label, _client) when is_binary(label), do: label
  defp normalize_client_label(label, _client), do: to_string(label)

  defp codex_client?(@codex_client_label, _client), do: true
  defp codex_client?(_label, CodexClient), do: true
  defp codex_client?(_label, _client), do: false

  defp legacy_warning(@legacy_runic_default) do
    ["legacy Runic default openai:gpt-5.4-mini remapped to Codex account default"]
  end

  defp legacy_warning(_model), do: []

  defp decision(
         requested_model,
         resolved_model,
         effective_model,
         provider,
         client_label,
         account_mode,
         decision,
         reason,
         warnings
       ) do
    %{
      requested_model: requested_model,
      resolved_model: resolved_model,
      effective_model: effective_model,
      provider: provider,
      client_label: client_label,
      account_mode: account_mode,
      decision: decision,
      reason: reason,
      warnings: warnings
    }
  end
end
