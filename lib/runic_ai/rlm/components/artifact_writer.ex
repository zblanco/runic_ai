defmodule RunicAI.RLM.Components.ArtifactWriter do
  @moduledoc """
  Guarded artifact writer for generated assistant workflows.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Components.BlueprintTransform

  @spec run(Workspace.t(), term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(%Workspace{} = workspace, input, params \\ %{}) do
    params = opts_map(params)
    path = get(params, :path, nil)
    write_policy = write_policy(get(params, :write_policy, :docs_only))

    with :ok <- validate_path(path),
         :ok <- enforce_write_policy(path, write_policy),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :write),
         content <- content(input, params),
         :ok <- File.mkdir_p(Path.dirname(resolved.path)),
         :ok <- File.write(resolved.path, content) do
      {:ok,
       %{
         status: :written,
         path: resolved.relative,
         absolute_path: resolved.path,
         bytes: byte_size(content),
         write_policy: write_policy
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp content(_input, %{content: content}) when is_binary(content), do: content
  defp content(_input, %{"content" => content}) when is_binary(content), do: content

  defp content(input, params) do
    case get(params, :template, nil) do
      template when is_binary(template) ->
        case BlueprintTransform.eval(%{op: "template", template: template, data: input}, input) do
          {:ok, rendered} -> rendered
          {:error, _error} -> fallback_content(input)
        end

      _other ->
        fallback_content(input)
    end
  end

  defp fallback_content(%{text: text}) when is_binary(text), do: text
  defp fallback_content(%{"text" => text}) when is_binary(text), do: text
  defp fallback_content(%{content: content}) when is_binary(content), do: content
  defp fallback_content(%{"content" => content}) when is_binary(content), do: content
  defp fallback_content(value) when is_binary(value), do: value
  defp fallback_content(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp validate_path(path) when is_binary(path) and path != "", do: :ok

  defp validate_path(path) do
    {:error,
     Error.validation("artifact writer requires a non-empty path",
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  defp enforce_write_policy(_path, :workspace_review), do: :ok
  defp enforce_write_policy(_path, :none), do: policy_error(:none)

  defp enforce_write_policy(path, :docs_only) do
    normalized = Path.expand(path, "/")
    docs_root = Path.expand(".docs", "/")

    if normalized == docs_root or String.starts_with?(normalized, docs_root <> "/") do
      :ok
    else
      policy_error(:docs_only, path)
    end
  end

  defp policy_error(policy, path \\ nil) do
    {:error,
     Error.validation("artifact write blocked by assistant write policy",
       source: __MODULE__,
       details: %{policy: policy, path: path}
     )}
  end

  defp write_policy(value) when value in [:none, :docs_only, :workspace_review], do: value
  defp write_policy("none"), do: :none
  defp write_policy("docs_only"), do: :docs_only
  defp write_policy("docs-only"), do: :docs_only
  defp write_policy("workspace_review"), do: :workspace_review
  defp write_policy("workspace-review"), do: :workspace_review
  defp write_policy(_value), do: :docs_only

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
