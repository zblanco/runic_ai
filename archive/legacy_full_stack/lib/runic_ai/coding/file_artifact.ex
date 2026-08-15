defmodule RunicAI.Coding.FileArtifact do
  @moduledoc """
  Model-visible file or log artifact summary.
  """

  alias RunicAI.Error

  @enforce_keys [:path, :sha256, :byte_size, :binary?, :truncated?, :metadata]
  defstruct [
    :path,
    :content,
    :preview,
    :sha256,
    :byte_size,
    :line_range,
    :artifact_ref,
    binary?: false,
    truncated?: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          content: binary() | nil,
          preview: binary() | nil,
          sha256: String.t() | nil,
          byte_size: non_neg_integer(),
          line_range: Range.t() | nil,
          artifact_ref: String.t() | nil,
          binary?: boolean(),
          truncated?: boolean(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    path = Keyword.get(opts, :path)
    content = Keyword.get(opts, :content)
    preview = Keyword.get(opts, :preview)
    sha256 = Keyword.get(opts, :sha256)
    byte_size = Keyword.get(opts, :byte_size, 0)
    line_range = Keyword.get(opts, :line_range)
    artifact_ref = Keyword.get(opts, :artifact_ref)
    binary? = Keyword.get(opts, :binary?, false)
    truncated? = Keyword.get(opts, :truncated?, false)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_path(path),
         :ok <- validate_optional_binary(content, :content),
         :ok <- validate_optional_binary(preview, :preview),
         :ok <- validate_sha256(sha256),
         :ok <- validate_byte_size(byte_size),
         :ok <- validate_line_range(line_range),
         :ok <- validate_optional_binary(artifact_ref, :artifact_ref),
         :ok <- validate_boolean(binary?, :binary?),
         :ok <- validate_boolean(truncated?, :truncated?),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         path: path,
         content: content,
         preview: preview,
         sha256: sha256,
         byte_size: byte_size,
         line_range: line_range,
         artifact_ref: artifact_ref,
         binary?: binary?,
         truncated?: truncated?,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, artifact} -> artifact
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = artifact) do
    new(
      path: artifact.path,
      content: artifact.content,
      preview: artifact.preview,
      sha256: artifact.sha256,
      byte_size: artifact.byte_size,
      line_range: artifact.line_range,
      artifact_ref: artifact.artifact_ref,
      binary?: artifact.binary?,
      truncated?: artifact.truncated?,
      metadata: artifact.metadata
    )
  end

  defp validate_path(nil), do: :ok
  defp validate_path(path) when is_binary(path), do: :ok

  defp validate_path(path) do
    {:error,
     Error.validation("file artifact path must be a string or nil",
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  defp validate_optional_binary(nil, _field), do: :ok
  defp validate_optional_binary(value, _field) when is_binary(value), do: :ok

  defp validate_optional_binary(value, field) do
    {:error,
     Error.validation("file artifact #{field} must be a binary or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_sha256(nil), do: :ok
  defp validate_sha256(hash) when is_binary(hash), do: :ok

  defp validate_sha256(hash) do
    {:error,
     Error.validation("file artifact sha256 must be a string or nil",
       source: __MODULE__,
       details: %{sha256: hash}
     )}
  end

  defp validate_byte_size(size) when is_integer(size) and size >= 0, do: :ok

  defp validate_byte_size(size) do
    {:error,
     Error.validation("file artifact byte_size must be a non-negative integer",
       source: __MODULE__,
       details: %{byte_size: size}
     )}
  end

  defp validate_line_range(nil), do: :ok
  defp validate_line_range(%Range{}), do: :ok

  defp validate_line_range(line_range) do
    {:error,
     Error.validation("file artifact line_range must be a Range or nil",
       source: __MODULE__,
       details: %{line_range: line_range}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("file artifact #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("file artifact metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
