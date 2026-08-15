defmodule RunicAI.Control.Suspension do
  @moduledoc "Review/wait suspension and validated resume contracts."

  alias RunicAI.Contract.Value
  alias RunicAI.Error
  alias RunicAI.JSONValue

  @request_wire "runic.ai/suspension-request/v1"
  @resume_wire "runic.ai/resume/v1"
  @kinds [:review, :wait]
  @outcomes [:approved, :rejected, :ready, :cancelled]

  defmodule Request do
    @moduledoc false
    @enforce_keys [:id, :kind, :reason, :resume]
    defstruct id: nil, kind: nil, reason: nil, resume: nil, payload: %{}, expires_at: nil
    @type t :: %__MODULE__{}
  end

  defmodule Resume do
    @moduledoc false
    @enforce_keys [:request_id, :outcome]
    defstruct request_id: nil, outcome: nil, value: nil, actor: nil, metadata: %{}
    @type t :: %__MODULE__{}
  end

  def request(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, kind} <- enum(Map.get(map, "kind"), @kinds, ["kind"]),
         true <- non_empty?(Map.get(map, "id")),
         true <- non_empty?(Map.get(map, "reason")),
         {:ok, resume} <- Value.normalize(Map.get(map, "resume", %{"type" => "any"})),
         payload when is_map(payload) <- Map.get(map, "payload", %{}) do
      {:ok,
       %Request{
         id: map["id"],
         kind: kind,
         reason: map["reason"],
         resume: resume,
         payload: payload,
         expires_at: map["expires_at"]
       }}
    else
      false -> error([], "suspension request fields are invalid")
      {:ok, _other} -> error([], "suspension request must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def request!(input), do: unwrap!(request(input))

  def resume(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         {:ok, outcome} <- enum(Map.get(map, "outcome"), @outcomes, ["outcome"]),
         true <- non_empty?(Map.get(map, "request_id")),
         metadata when is_map(metadata) <- Map.get(map, "metadata", %{}) do
      {:ok,
       %Resume{
         request_id: map["request_id"],
         outcome: outcome,
         value: map["value"],
         actor: map["actor"],
         metadata: metadata
       }}
    else
      false -> error([], "resume fields are invalid")
      {:ok, _other} -> error([], "resume must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def resume!(input), do: unwrap!(resume(input))

  def resolve(%Request{} = request, %Resume{request_id: request_id} = resume) do
    cond do
      request.id != request_id ->
        {:error,
         Error.new!(:conflict, "resume_request_mismatch", "resume does not match suspension")}

      resume.outcome in [:rejected, :cancelled] ->
        {:error,
         Error.new!(:denied, "resume_denied", "suspended execution was not approved",
           details: %{"outcome" => Atom.to_string(resume.outcome)}
         )}

      true ->
        case Value.validate_value(request.resume, resume.value) do
          :ok ->
            {:ok, resume.value}

          {:error, issues} ->
            {:error,
             Error.validation("resume value failed validation",
               code: "invalid_resume_value",
               details: %{"issues" => issues}
             )}
        end
    end
  end

  def encode(%Request{} = request),
    do:
      compact(%{
        "$contract" => @request_wire,
        "id" => request.id,
        "kind" => Atom.to_string(request.kind),
        "reason" => request.reason,
        "resume" => Value.encode(request.resume),
        "payload" => request.payload,
        "expires_at" => request.expires_at
      })

  def encode(%Resume{} = resume),
    do:
      compact(%{
        "$contract" => @resume_wire,
        "request_id" => resume.request_id,
        "outcome" => Atom.to_string(resume.outcome),
        "value" => resume.value,
        "actor" => resume.actor,
        "metadata" => resume.metadata
      })

  def decode(%{"$contract" => @request_wire} = input), do: request(input)
  def decode(%{"$contract" => @resume_wire} = input), do: resume(input)
  def decode(_input), do: error(["$contract"], "is not a supported suspension contract")

  defp enum(value, allowed, path) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error(path, "is not supported")
      item -> {:ok, item}
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp non_empty?(value), do: is_binary(value) and value != ""
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, issues}), do: raise(ArgumentError, inspect(issues))
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
