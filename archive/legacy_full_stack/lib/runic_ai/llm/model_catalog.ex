defmodule RunicAI.LLM.ModelCatalog do
  @moduledoc """
  Workbench-facing model catalog derived from ReqLLM and LLMDB metadata.
  """

  @default_provider :openai
  @default_model_id "gpt-5.4-mini"
  @preferred_providers [
    :openai,
    :anthropic,
    :google,
    :google_vertex,
    :xai,
    :groq,
    :cerebras,
    :mistral,
    :openrouter
  ]

  @type model_option :: %{id: String.t(), label: String.t(), spec: String.t()}
  @type provider_option :: %{id: String.t(), label: String.t(), models: [model_option()]}

  @spec default_provider() :: atom()
  def default_provider, do: @default_provider

  @spec default_model_id() :: String.t()
  def default_model_id, do: @default_model_id

  @spec default_model_spec() :: String.t()
  def default_model_spec, do: LLMDB.format({@default_provider, @default_model_id})

  @spec catalog(keyword()) :: map()
  def catalog(opts \\ []) do
    providers =
      opts
      |> model_specs()
      |> grouped_provider_options()
      |> ensure_default_model()
      |> sort_providers()

    %{
      default_provider: Atom.to_string(@default_provider),
      default_model_id: @default_model_id,
      default_model: default_model_spec(),
      providers: providers,
      provider_models: Map.new(providers, &{&1.id, &1.models})
    }
  end

  defp model_specs(opts) do
    case configured_model_specs(opts) do
      [] -> fallback_model_specs()
      specs -> specs
    end
  end

  defp configured_model_specs(opts) do
    opts
    |> Keyword.put_new(:require, chat: true)
    |> ReqLLM.Availability.available_models()
    |> Enum.flat_map(&load_text_generation_spec/1)
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  defp fallback_model_specs do
    supported_providers = MapSet.new(ReqLLM.Providers.list())

    LLMDB.Query.candidates(require: [chat: true], prefer: @preferred_providers)
    |> Enum.filter(fn {provider, _model_id} -> MapSet.member?(supported_providers, provider) end)
    |> Enum.flat_map(&load_text_generation_spec/1)
  end

  defp load_text_generation_spec({provider, model_id}) when is_atom(provider) do
    case LLMDB.model(provider, model_id) do
      {:ok, model} -> text_generation_spec(model)
      _other -> []
    end
  end

  defp load_text_generation_spec(spec) when is_binary(spec) do
    case LLMDB.model(spec) do
      {:ok, model} -> text_generation_spec(model)
      _other -> []
    end
  end

  defp text_generation_spec(%LLMDB.Model{} = model) do
    if text_generation_model?(model) do
      [{model.provider, model.id, model}]
    else
      []
    end
  end

  defp text_generation_model?(%LLMDB.Model{} = model) do
    execution_supported?(model, :text) and not retired?(model)
  end

  defp execution_supported?(%LLMDB.Model{execution: execution}, operation)
       when is_map(execution) do
    execution
    |> Map.get(operation, Map.get(execution, Atom.to_string(operation), %{}))
    |> supported?()
  end

  defp execution_supported?(_model, _operation), do: false

  defp supported?(%{supported: true}), do: true
  defp supported?(%{"supported" => true}), do: true
  defp supported?(_execution), do: false

  defp retired?(%LLMDB.Model{} = model) do
    status =
      model.lifecycle
      |> case do
        %{status: status} -> status
        %{"status" => status} -> status
        _other -> nil
      end

    status == "retired" or Map.get(model, :retired) == true
  end

  defp grouped_provider_options(model_specs) do
    model_specs
    |> Enum.uniq_by(fn {provider, model_id, _model} -> {provider, model_id} end)
    |> Enum.group_by(fn {provider, _model_id, _model} -> provider end)
    |> Enum.map(fn {provider, specs} ->
      %{
        id: Atom.to_string(provider),
        label: provider_label(provider),
        models:
          specs
          |> Enum.map(fn {_provider, model_id, model} ->
            %{id: model_id, label: model_label(model), spec: LLMDB.format({provider, model_id})}
          end)
          |> sort_models(provider)
      }
    end)
  end

  defp ensure_default_model(providers) do
    default_provider = Atom.to_string(@default_provider)

    if has_model?(providers, default_provider, @default_model_id) do
      providers
    else
      default_option = %{
        id: @default_model_id,
        label: @default_model_id,
        spec: default_model_spec()
      }

      upsert_provider_model(
        providers,
        default_provider,
        provider_label(@default_provider),
        default_option
      )
    end
  end

  defp has_model?(providers, provider_id, model_id) do
    Enum.any?(providers, fn provider ->
      provider.id == provider_id and Enum.any?(provider.models, &(&1.id == model_id))
    end)
  end

  defp upsert_provider_model([], provider_id, provider_label, model) do
    [%{id: provider_id, label: provider_label, models: [model]}]
  end

  defp upsert_provider_model([%{id: provider_id} = provider | rest], provider_id, _label, model) do
    [%{provider | models: sort_models([model | provider.models], provider_id)} | rest]
  end

  defp upsert_provider_model([provider | rest], provider_id, provider_label, model) do
    [provider | upsert_provider_model(rest, provider_id, provider_label, model)]
  end

  defp sort_providers(providers) do
    Enum.sort_by(providers, fn provider ->
      preferred_index =
        @preferred_providers
        |> Enum.map(&Atom.to_string/1)
        |> Enum.find_index(&(&1 == provider.id))

      {preferred_index || 999, provider.label}
    end)
  end

  defp sort_models(models, provider) when is_atom(provider),
    do: sort_models(models, Atom.to_string(provider))

  defp sort_models(models, "openai") do
    Enum.sort_by(models, fn model ->
      if model.id == @default_model_id, do: {"0", model.label}, else: {"1", model.label}
    end)
  end

  defp sort_models(models, _provider), do: Enum.sort_by(models, & &1.label)

  defp provider_label(provider) do
    case LLMDB.provider(provider) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _other -> provider |> Atom.to_string() |> String.replace("_", " ")
    end
  end

  defp model_label(%LLMDB.Model{name: name, id: id}) when is_binary(name) and name != "" do
    "#{name} (#{id})"
  end

  defp model_label(%LLMDB.Model{id: id}), do: id
end
