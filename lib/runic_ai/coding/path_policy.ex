defmodule RunicAI.Coding.PathPolicy do
  @moduledoc """
  Workspace path policy for local coding tools.

  The policy is intentionally conservative: callers pass workspace-relative
  paths, all paths are resolved through `Path.safe_relative/2`, symlink escapes
  are rejected, and credential-looking paths are blocked unless explicitly
  allowed.
  """

  alias RunicAI.Error

  @valid_hidden_policies [:allow, :deny, :read_only]
  @valid_symlink_policies [:allow, :reject]

  @credential_names MapSet.new([
                      ".aws",
                      ".env",
                      ".netrc",
                      ".npmrc",
                      ".pypirc",
                      ".ssh",
                      "credentials",
                      "id_dsa",
                      "id_ecdsa",
                      "id_ed25519",
                      "id_rsa",
                      "secrets"
                    ])

  @enforce_keys [
    :root_jail,
    :read_root_jail,
    :symlink_policy,
    :hidden_policy,
    :max_file_bytes,
    :allowed_write_roots,
    :allow_credential_paths,
    :metadata
  ]
  defstruct root_jail: true,
            read_root_jail: true,
            symlink_policy: :reject,
            hidden_policy: :read_only,
            max_file_bytes: 1_048_576,
            allowed_write_roots: ["."],
            allow_credential_paths: false,
            metadata: %{}

  @type hidden_policy :: :allow | :deny | :read_only
  @type symlink_policy :: :allow | :reject
  @type access :: :read | :write

  @type resolved_path :: %{
          required(:path) => Path.t(),
          required(:relative) => Path.t()
        }

  @type t :: %__MODULE__{
          root_jail: boolean(),
          read_root_jail: boolean(),
          symlink_policy: symlink_policy(),
          hidden_policy: hidden_policy(),
          max_file_bytes: pos_integer(),
          allowed_write_roots: [Path.t()],
          allow_credential_paths: boolean(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    root_jail = Keyword.get(opts, :root_jail, true)
    read_root_jail = Keyword.get(opts, :read_root_jail, root_jail)
    symlink_policy = Keyword.get(opts, :symlink_policy, :reject)
    hidden_policy = Keyword.get(opts, :hidden_policy, :read_only)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, 1_048_576)
    allowed_write_roots = Keyword.get(opts, :allowed_write_roots, ["."])
    allow_credential_paths = Keyword.get(opts, :allow_credential_paths, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_boolean(root_jail, :root_jail),
         :ok <- validate_boolean(read_root_jail, :read_root_jail),
         :ok <- validate_symlink_policy(symlink_policy),
         :ok <- validate_hidden_policy(hidden_policy),
         :ok <- validate_max_file_bytes(max_file_bytes),
         :ok <- validate_allowed_write_roots(allowed_write_roots),
         :ok <- validate_boolean(allow_credential_paths, :allow_credential_paths),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         root_jail: root_jail,
         read_root_jail: read_root_jail,
         symlink_policy: symlink_policy,
         hidden_policy: hidden_policy,
         max_file_bytes: max_file_bytes,
         allowed_write_roots: allowed_write_roots,
         allow_credential_paths: allow_credential_paths,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      root_jail: get(input, :root_jail, true),
      read_root_jail: get(input, :read_root_jail, get(input, :root_jail, true)),
      symlink_policy: get(input, :symlink_policy, :reject),
      hidden_policy: get(input, :hidden_policy, :read_only),
      max_file_bytes: get(input, :max_file_bytes, 1_048_576),
      allowed_write_roots: get(input, :allowed_write_roots, ["."]),
      allow_credential_paths: get(input, :allow_credential_paths, false),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.PathPolicy-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | map() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      root_jail: policy.root_jail,
      read_root_jail: policy.read_root_jail,
      symlink_policy: policy.symlink_policy,
      hidden_policy: policy.hidden_policy,
      max_file_bytes: policy.max_file_bytes,
      allowed_write_roots: policy.allowed_write_roots,
      allow_credential_paths: policy.allow_credential_paths,
      metadata: policy.metadata
    )
  end

  @spec resolve(t(), Path.t(), Path.t(), access()) :: {:ok, resolved_path()} | {:error, Error.t()}
  def resolve(%__MODULE__{} = policy, root, path, access \\ :read)
      when is_binary(root) and access in [:read, :write] do
    root = Path.expand(root)

    with {:ok, %{path: absolute, relative: relative}} <-
           expand_path(policy, root, path, access),
         :ok <- enforce_root_jail(policy, absolute, root, access),
         :ok <- enforce_hidden_policy(policy, relative, access),
         :ok <- enforce_credential_policy(policy, relative),
         :ok <- enforce_symlink_policy(policy, absolute, access),
         :ok <- enforce_write_roots(policy, absolute, root, access) do
      {:ok, %{path: absolute, relative: normalize_relative(relative)}}
    end
  end

  @spec hidden?(Path.t()) :: boolean()
  def hidden?(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.any?(fn component ->
      component not in [".", "..", ""] and String.starts_with?(component, ".")
    end)
  end

  @spec credential_path?(Path.t()) :: boolean()
  def credential_path?(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.any?(fn component ->
      normalized = String.downcase(component)

      MapSet.member?(@credential_names, normalized) or
        String.contains?(normalized, "secret") or
        String.contains?(normalized, "credential")
    end)
  end

  defp expand_path(%__MODULE__{} = policy, root, path, access) when is_binary(path) do
    cond do
      path in ["", "."] ->
        {:ok, %{path: root, relative: "."}}

      Path.type(path) == :relative ->
        case Path.safe_relative(path, root) do
          {:ok, relative} ->
            relative = normalize_relative(relative)
            {:ok, %{path: Path.expand(relative, root), relative: relative}}

          :error ->
            if access == :read and not policy.read_root_jail do
              absolute = Path.expand(path, root)
              {:ok, %{path: absolute, relative: absolute}}
            else
              path_error(path, "path escapes the workspace root")
            end
        end

      access == :read and not policy.read_root_jail ->
        absolute = Path.expand(path)
        {:ok, %{path: absolute, relative: absolute}}

      true ->
        path_error(path, "path must be workspace-relative")
    end
  end

  defp expand_path(_policy, _root, path, _access) do
    path_error(path, "path must be a string")
  end

  defp enforce_root_jail(%__MODULE__{} = policy, absolute, root, :read) do
    if policy.read_root_jail do
      enforce_inside_root(absolute, root)
    else
      :ok
    end
  end

  defp enforce_root_jail(%__MODULE__{root_jail: false}, _absolute, _root, :write), do: :ok

  defp enforce_root_jail(%__MODULE__{root_jail: true}, absolute, root, :write) do
    enforce_inside_root(absolute, root)
  end

  defp enforce_inside_root(absolute, root) do
    if inside?(absolute, root) do
      :ok
    else
      path_error(absolute, "path escapes the workspace root")
    end
  end

  defp enforce_hidden_policy(%__MODULE__{hidden_policy: :allow}, _relative, _access), do: :ok

  defp enforce_hidden_policy(%__MODULE__{hidden_policy: :read_only}, relative, :read) do
    if hidden?(relative), do: :ok, else: :ok
  end

  defp enforce_hidden_policy(%__MODULE__{hidden_policy: :read_only}, relative, :write) do
    if hidden?(relative), do: path_error(relative, "hidden paths are read-only"), else: :ok
  end

  defp enforce_hidden_policy(%__MODULE__{hidden_policy: :deny}, relative, _access) do
    if hidden?(relative), do: path_error(relative, "hidden paths are not allowed"), else: :ok
  end

  defp enforce_credential_policy(%__MODULE__{allow_credential_paths: true}, _relative), do: :ok

  defp enforce_credential_policy(%__MODULE__{allow_credential_paths: false}, relative) do
    if credential_path?(relative) do
      path_error(relative, "credential-looking paths are not allowed")
    else
      :ok
    end
  end

  defp enforce_symlink_policy(%__MODULE__{symlink_policy: :allow}, _absolute, _access),
    do: :ok

  defp enforce_symlink_policy(%__MODULE__{symlink_policy: :reject}, absolute, access) do
    paths = existing_component_paths(absolute, access)

    case Enum.find(paths, &symlink?/1) do
      nil -> :ok
      path -> path_error(path, "symbolic links are not allowed by this workspace policy")
    end
  end

  defp enforce_write_roots(_policy, _absolute, _root, :read), do: :ok

  defp enforce_write_roots(%__MODULE__{allowed_write_roots: roots}, absolute, root, :write) do
    if Enum.any?(roots, &inside_allowed_write_root?(&1, absolute, root)) do
      :ok
    else
      path_error(absolute, "path is outside allowed write roots")
    end
  end

  defp existing_component_paths(absolute, access) do
    paths = path_prefixes(Path.expand(absolute))

    case access do
      :read -> paths
      :write -> Enum.take_while(paths, &File.exists?/1)
    end
  end

  defp path_prefixes(absolute) do
    absolute
    |> Path.split()
    |> Enum.reduce([], fn
      "/", [] ->
        ["/"]

      component, [] ->
        [component]

      component, acc ->
        acc ++ [Path.join(List.last(acc), component)]
    end)
    |> Enum.reject(&(&1 in ["", "/"]))
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _other -> false
    end
  end

  defp inside_allowed_write_root?(allowed_root, absolute, root) do
    with {:ok, relative_root} <- write_root_relative(allowed_root, root) do
      allowed_absolute = Path.expand(relative_root, root)
      inside?(absolute, allowed_absolute)
    else
      _error -> false
    end
  end

  defp write_root_relative(path, _root) when path in ["", "."], do: {:ok, "."}

  defp write_root_relative(path, root) when is_binary(path) do
    if Path.type(path) == :relative do
      case Path.safe_relative(path, root) do
        {:ok, relative} -> {:ok, normalize_relative(relative)}
        :error -> path_error(path, "path escapes the workspace root")
      end
    else
      path_error(path, "path must be workspace-relative")
    end
  end

  defp write_root_relative(path, _root), do: path_error(path, "path must be a string")

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)

    path == root or List.starts_with?(Path.split(path), Path.split(root))
  end

  defp normalize_relative("."), do: "."
  defp normalize_relative(""), do: "."
  defp normalize_relative(relative), do: relative

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("path policy #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_symlink_policy(policy) when policy in @valid_symlink_policies, do: :ok

  defp validate_symlink_policy(policy) do
    {:error,
     Error.validation("invalid symlink policy",
       source: __MODULE__,
       details: %{policy: policy, valid_policies: @valid_symlink_policies}
     )}
  end

  defp validate_hidden_policy(policy) when policy in @valid_hidden_policies, do: :ok

  defp validate_hidden_policy(policy) do
    {:error,
     Error.validation("invalid hidden-file policy",
       source: __MODULE__,
       details: %{policy: policy, valid_policies: @valid_hidden_policies}
     )}
  end

  defp validate_max_file_bytes(bytes) when is_integer(bytes) and bytes > 0, do: :ok

  defp validate_max_file_bytes(bytes) do
    {:error,
     Error.validation("path policy max_file_bytes must be a positive integer",
       source: __MODULE__,
       details: %{max_file_bytes: bytes}
     )}
  end

  defp validate_allowed_write_roots(roots) when is_list(roots) and roots != [] do
    if Enum.all?(roots, &is_binary/1) do
      :ok
    else
      invalid_allowed_write_roots(roots)
    end
  end

  defp validate_allowed_write_roots(roots), do: invalid_allowed_write_roots(roots)

  defp invalid_allowed_write_roots(roots) do
    {:error,
     Error.validation("path policy allowed_write_roots must be a non-empty list of strings",
       source: __MODULE__,
       details: %{allowed_write_roots: roots}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("path policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp path_error(path, message) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  defp get(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
