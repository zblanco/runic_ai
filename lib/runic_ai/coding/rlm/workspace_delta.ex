defmodule RunicAI.Coding.RLM.WorkspaceDelta do
  @moduledoc """
  Lightweight workspace snapshot and delta helpers for repair attempts.

  Repair children can time out after writing useful files. The repair loop uses
  this module to observe filesystem changes before and after an attempt so the
  next iteration can continue from current workspace state instead of treating a
  timeout as total loss.
  """

  alias RunicAI.Coding.Workspace

  @excluded_segments MapSet.new([
                       ".git",
                       "_build",
                       "deps",
                       "node_modules",
                       ".elixir_ls",
                       "cover",
                       "doc",
                       "dist",
                       "build",
                       "tmp",
                       ".runic_ai"
                     ])

  @type file_info :: %{
          required(:path) => Path.t(),
          required(:bytes) => non_neg_integer(),
          required(:sha256) => String.t()
        }

  @type snapshot :: %{
          required(:root) => Path.t(),
          required(:files) => %{Path.t() => file_info()},
          required(:taken_at) => DateTime.t()
        }

  @type delta :: %{
          required(:created) => [Path.t()],
          required(:modified) => [Path.t()],
          required(:deleted) => [Path.t()],
          required(:unchanged) => [Path.t()]
        }

  @spec snapshot(Workspace.t(), keyword()) :: snapshot()
  def snapshot(%Workspace{} = workspace, opts \\ []) when is_list(opts) do
    max_files = Keyword.get(opts, :max_files, 1_000)

    files =
      workspace.root
      |> all_regular_files()
      |> Enum.take(max_files)
      |> Map.new(fn path ->
        {:ok, relative} = Workspace.relative_path(workspace, path)
        {relative, file_info(relative, path)}
      end)

    %{root: workspace.root, files: files, taken_at: DateTime.utc_now()}
  end

  @spec diff(snapshot(), snapshot()) :: delta()
  def diff(%{files: before_files}, %{files: after_files}) do
    before_paths = MapSet.new(Map.keys(before_files))
    after_paths = MapSet.new(Map.keys(after_files))

    created =
      after_paths
      |> MapSet.difference(before_paths)
      |> MapSet.to_list()
      |> Enum.sort()

    deleted =
      before_paths
      |> MapSet.difference(after_paths)
      |> MapSet.to_list()
      |> Enum.sort()

    common = MapSet.intersection(before_paths, after_paths)

    {modified, unchanged} =
      common
      |> Enum.split_with(fn path ->
        before_files[path].sha256 != after_files[path].sha256 or
          before_files[path].bytes != after_files[path].bytes
      end)

    %{
      created: Enum.sort(modified_paths(created)),
      modified: Enum.sort(modified_paths(modified)),
      deleted: Enum.sort(modified_paths(deleted)),
      unchanged: Enum.sort(unchanged)
    }
  end

  @spec changed_paths(delta()) :: [Path.t()]
  def changed_paths(delta) when is_map(delta) do
    delta
    |> Map.take([:created, :modified, :deleted])
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp modified_paths(paths), do: Enum.filter(paths, &is_binary/1)

  defp all_regular_files(root) do
    root
    |> File.ls()
    |> case do
      {:ok, names} ->
        names
        |> Enum.reject(&excluded_path?/1)
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)

          cond do
            File.dir?(path) -> all_regular_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp excluded_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_segments, &1))
  end

  defp file_info(relative, path) do
    content = File.read!(path)

    %{
      path: relative,
      bytes: byte_size(content),
      sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    }
  end
end
