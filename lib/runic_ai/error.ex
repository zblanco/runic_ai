defmodule RunicAI.Error do
  @moduledoc "A safe, serializable error returned by RunicAI effect boundaries."

  alias RunicAI.JSONValue

  @kinds [:validation, :provider, :timeout, :unavailable, :denied, :conflict, :internal]
  @wire_id "runic.ai/error/v1"

  @enforce_keys [:kind, :code, :message]
  defstruct kind: nil,
            code: nil,
            message: nil,
            retryable: false,
            details: %{},
            source: nil,
            cause: nil,
            request_ref: nil

  @type kind ::
          :validation | :provider | :timeout | :unavailable | :denied | :conflict | :internal
  @type t :: %__MODULE__{}

  @spec new(kind(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, [JSONValue.issue()]}
  def new(kind, code, message, opts \\ []) when is_list(opts) do
    with {:ok, details} <- JSONValue.normalize(Keyword.get(opts, :details, %{})) do
      error = %__MODULE__{
        kind: kind,
        code: code,
        message: message,
        retryable: Keyword.get(opts, :retryable, false),
        details: details,
        source: Keyword.get(opts, :source),
        cause: normalize_cause(Keyword.get(opts, :cause)),
        request_ref: Keyword.get(opts, :request_ref)
      }

      validate(error)
    end
  end

  @spec new!(kind(), String.t(), String.t(), keyword()) :: t()
  def new!(kind, code, message, opts \\ []) do
    case new(kind, code, message, opts) do
      {:ok, error} -> error
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  @spec validation(String.t(), keyword()) :: t()
  def validation(message, opts \\ []),
    do: new!(:validation, Keyword.get(opts, :code, "invalid_input"), message, opts)

  @spec provider(String.t(), keyword()) :: t()
  def provider(message, opts \\ []),
    do: new!(:provider, Keyword.get(opts, :code, "provider_error"), message, opts)

  @spec from_exception(Exception.t(), keyword()) :: t()
  def from_exception(exception, opts \\ []) do
    new!(
      Keyword.get(opts, :kind, :internal),
      Keyword.get(opts, :code, "exception"),
      Keyword.get(opts, :message, "an unexpected exception occurred"),
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details, %{}),
      source: Keyword.get(opts, :source),
      cause: exception
    )
  end

  @spec validate(t()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def validate(%__MODULE__{} = error) do
    issues =
      []
      |> check(error.kind in @kinds, ["kind"], "is not supported")
      |> check(
        is_binary(error.code) and Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, error.code || ""),
        ["code"],
        "must be a stable lowercase identifier"
      )
      |> check(
        is_binary(error.message) and error.message != "",
        ["message"],
        "must be a non-empty string"
      )
      |> check(is_boolean(error.retryable), ["retryable"], "must be a boolean")
      |> check(json_safe?(error.details), ["details"], "must be JSON-safe")
      |> check(
        is_nil(error.source) or is_binary(error.source),
        ["source"],
        "must be a string or null"
      )
      |> check(
        is_nil(error.cause) or json_safe?(error.cause),
        ["cause"],
        "must be a safe summary"
      )
      |> check(
        is_nil(error.request_ref) or is_binary(error.request_ref),
        ["request_ref"],
        "must be a redacted string reference or null"
      )
      |> Enum.reverse()

    if issues == [], do: {:ok, error}, else: {:error, issues}
  end

  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = error) do
    %{
      "$contract" => @wire_id,
      "kind" => Atom.to_string(error.kind),
      "code" => error.code,
      "message" => error.message,
      "retryable" => error.retryable,
      "details" => JSONValue.normalize!(error.details)
    }
    |> put_if("source", error.source, not is_nil(error.source))
    |> put_if("cause", error.cause, not is_nil(error.cause))
    |> put_if("request_ref", error.request_ref, not is_nil(error.request_ref))
  end

  @spec decode(term()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id,
         {:ok, kind} <- decode_kind(Map.get(map, "kind")) do
      new(kind, Map.get(map, "code"), Map.get(map, "message"),
        retryable: Map.get(map, "retryable", false),
        details: Map.get(map, "details", %{}),
        source: Map.get(map, "source"),
        cause: Map.get(map, "cause"),
        request_ref: Map.get(map, "request_ref")
      )
    else
      false -> {:error, [%{path: ["$contract"], message: "is not #{@wire_id}"}]}
      {:ok, _other} -> {:error, [%{path: [], message: "error must be an object"}]}
      {:error, issues} -> {:error, issues}
    end
  end

  defp decode_kind(value) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == value)) do
      nil -> {:error, [%{path: ["kind"], message: "is not supported"}]}
      kind -> {:ok, kind}
    end
  end

  defp normalize_cause(nil), do: nil

  defp normalize_cause(%{__exception__: true} = exception),
    do: %{"type" => inspect(exception.__struct__)}

  defp normalize_cause(cause) when is_binary(cause), do: %{"message" => cause}
  defp normalize_cause(cause) when is_map(cause), do: JSONValue.normalize!(cause)
  defp normalize_cause(_cause), do: %{"type" => "unavailable"}

  defp json_safe?(value), do: match?({:ok, _}, JSONValue.normalize(value))
  defp check(issues, true, _path, _message), do: issues
  defp check(issues, false, path, message), do: [%{path: path, message: message} | issues]
  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
end
