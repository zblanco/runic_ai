defmodule RunicAI.Coding.Workspace do
  @moduledoc """
  Local project workspace for coding-agent tools.

  A workspace carries the root directory, the path policy used by every file
  operation, the detected language profile, optional persistence handle, and
  caller metadata.
  """

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Profile
  alias RunicAI.Error

  @enforce_keys [:root, :path_policy, :profile, :metadata]
  defstruct [:root, :path_policy, :profile, :persistence, :metadata]

  @type t :: %__MODULE__{
          root: Path.t(),
          path_policy: PathPolicy.t(),
          profile: Profile.t(),
          persistence: term(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    root = Keyword.get(opts, :root)
    metadata = Keyword.get(opts, :metadata, %{})
    persistence = Keyword.get(opts, :persistence)

    with {:ok, root} <- normalize_root(root),
         {:ok, path_policy} <- PathPolicy.from_input(Keyword.get(opts, :path_policy)),
         {:ok, profile} <- normalize_profile(Keyword.get(opts, :profile), root),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         root: root,
         path_policy: path_policy,
         profile: profile,
         persistence: persistence,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, workspace} -> workspace
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = workspace), do: validate(workspace)
  def from_input(root) when is_binary(root), do: new(root: root)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      root: get(input, :root, nil),
      path_policy: get(input, :path_policy, nil),
      profile: get(input, :profile, nil),
      persistence: get(input, :persistence, nil),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.Workspace-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | map() | Path.t()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, workspace} -> workspace
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = workspace) do
    new(
      root: workspace.root,
      path_policy: workspace.path_policy,
      profile: workspace.profile,
      persistence: workspace.persistence,
      metadata: workspace.metadata
    )
  end

  @spec resolve_path(t(), Path.t(), PathPolicy.access()) ::
          {:ok, PathPolicy.resolved_path()} | {:error, Error.t()}
  def resolve_path(%__MODULE__{} = workspace, path, access \\ :read) do
    with {:ok, path} <- normalize_tool_path(workspace, path) do
      PathPolicy.resolve(workspace.path_policy, workspace.root, path, access)
    end
  end

  @spec relative_path(t(), Path.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def relative_path(%__MODULE__{root: root}, absolute_path) when is_binary(absolute_path) do
    absolute_path = Path.expand(absolute_path)
    root = Path.expand(root)

    if absolute_path == root or List.starts_with?(Path.split(absolute_path), Path.split(root)) do
      {:ok, Path.relative_to(absolute_path, root)}
    else
      {:error,
       Error.validation("absolute path is outside workspace root",
         source: __MODULE__,
         details: %{path: absolute_path, root: root}
       )}
    end
  end

  defp normalize_tool_path(%__MODULE__{} = workspace, path) when is_binary(path) do
    if Path.type(path) == :absolute do
      relative_path(workspace, path)
    else
      {:ok, path}
    end
  end

  defp normalize_tool_path(_workspace, path), do: {:ok, path}

  defp normalize_root(root) when is_binary(root) and root != "" do
    root = Path.expand(root)

    cond do
      not File.exists?(root) ->
        {:error,
         Error.validation("workspace root does not exist",
           source: __MODULE__,
           details: %{root: root}
         )}

      not File.dir?(root) ->
        {:error,
         Error.validation("workspace root must be a directory",
           source: __MODULE__,
           details: %{root: root}
         )}

      true ->
        {:ok, root}
    end
  end

  defp normalize_root(root) do
    {:error,
     Error.validation("workspace root must be a non-empty string",
       source: __MODULE__,
       details: %{root: root}
     )}
  end

  defp normalize_profile(nil, root), do: Profile.detect(root)
  defp normalize_profile(profile, _root), do: Profile.from_input(profile)

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("workspace metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
