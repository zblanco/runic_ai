defmodule RunicAI.Evaluation.Result do
  @moduledoc """
  Case-level evaluation result.
  """

  alias RunicAI.Error
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Expectation
  alias RunicAI.Harness.Session
  alias RunicAI.Message
  alias RunicAI.Trace.Trajectory

  @valid_statuses [:passed, :failed, :error]

  @enforce_keys [:case_id, :status, :scores, :metrics, :failures, :metadata]
  defstruct [
    :case_id,
    :status,
    :session,
    outputs: [],
    trajectory: nil,
    scores: %{},
    metrics: %{},
    failures: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          case_id: String.t(),
          status: :passed | :failed | :error,
          session: Session.t() | nil,
          outputs: [term()],
          trajectory: Trajectory.t() | nil,
          scores: map(),
          metrics: map(),
          failures: [map()],
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(case_id, opts \\ []) when is_binary(case_id) and is_list(opts) do
    scores = Keyword.get(opts, :scores, %{})
    metrics = Keyword.get(opts, :metrics, %{})
    failures = Keyword.get(opts, :failures, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_status(Keyword.get(opts, :status)),
         :ok <- validate_scores(scores),
         :ok <- validate_metrics(metrics),
         :ok <- validate_failures(failures),
         :ok <- validate_metadata(metadata),
         {:ok, session} <- normalize_session(Keyword.get(opts, :session)),
         {:ok, trajectory} <-
           normalize_trajectory(Keyword.get(opts, :trajectory, session && session.trajectory)),
         :ok <- validate_outputs(Keyword.get(opts, :outputs, (session && session.outputs) || [])) do
      {:ok,
       %__MODULE__{
         case_id: case_id,
         status: Keyword.get(opts, :status),
         session: session,
         outputs: Keyword.get(opts, :outputs, (session && session.outputs) || []),
         trajectory: trajectory,
         scores: scores,
         metrics: metrics,
         failures: failures,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(case_id, opts \\ []) do
    case new(case_id, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_session(Case.t(), Session.t(), keyword()) :: t()
  def from_session(%Case{} = evaluation_case, %Session{} = session, opts \\ []) do
    base_result =
      %__MODULE__{
        case_id: evaluation_case.id,
        status: :passed,
        session: session,
        outputs: session.outputs,
        trajectory: session.trajectory,
        scores: %{},
        metrics: session.measurements,
        failures: [],
        metadata: Keyword.get(opts, :metadata, %{})
      }

    {scores, failures} = Expectation.evaluate_all(base_result, evaluation_case.expected)
    status = derive_status(session, failures)

    new!(
      evaluation_case.id,
      status: status,
      session: session,
      outputs: session.outputs,
      trajectory: session.trajectory,
      scores: scores,
      metrics: session.measurements,
      failures: failures,
      metadata:
        Map.merge(
          %{
            tags: evaluation_case.tags,
            case_metadata: evaluation_case.metadata
          },
          Keyword.get(opts, :metadata, %{})
        )
    )
  end

  @spec reply_text(t()) :: String.t() | nil
  def reply_text(%__MODULE__{outputs: outputs, trajectory: trajectory}) do
    outputs
    |> Enum.reverse()
    |> Enum.find_value(&reply_text_from_output/1) ||
      trajectory_reply_text(trajectory)
  end

  @spec tool_called?(t(), String.t() | nil) :: boolean()
  def tool_called?(result, tool_name \\ nil)

  def tool_called?(%__MODULE__{trajectory: %Trajectory{} = trajectory}, tool_name) do
    trajectory.events
    |> Enum.any?(fn event ->
      event.kind in [:tool_call, :tool_result] and tool_name_matches?(event.output, tool_name)
    end)
  end

  def tool_called?(%__MODULE__{}, _tool_name), do: false

  @spec review_required?(t()) :: boolean()
  def review_required?(%__MODULE__{trajectory: %Trajectory{} = trajectory}) do
    Trajectory.count_events(trajectory, :review_requested) > 0
  end

  def review_required?(%__MODULE__{}), do: false

  @spec wait_required?(t()) :: boolean()
  def wait_required?(%__MODULE__{trajectory: %Trajectory{} = trajectory}) do
    Trajectory.count_events(trajectory, :wait_registered) > 0
  end

  def wait_required?(%__MODULE__{}), do: false

  defp derive_status(%Session{status: :error}, _failures), do: :error
  defp derive_status(_session, []), do: :passed
  defp derive_status(_session, _failures), do: :failed

  defp reply_text_from_output(%{reply_text: reply_text}) when is_binary(reply_text),
    do: reply_text

  defp reply_text_from_output(%{latest_reply_text: reply_text}) when is_binary(reply_text),
    do: reply_text

  defp reply_text_from_output(%{turn_result: %{message: %Message{content: content}}})
       when is_binary(content),
       do: content

  defp reply_text_from_output(%{latest_turn_result: %{message: %Message{content: content}}})
       when is_binary(content),
       do: content

  defp reply_text_from_output(%{emissions: emissions}) when is_list(emissions) do
    emissions
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{value: %{message: %Message{content: content}}} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp reply_text_from_output(_output), do: nil

  defp trajectory_reply_text(nil), do: nil

  defp trajectory_reply_text(%Trajectory{} = trajectory) do
    trajectory.events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{output: %{message: %Message{content: content}}} when is_binary(content) ->
        content

      %{output: %{value: %{message: %Message{content: content}}}} when is_binary(content) ->
        content

      %{output: %{reply_text: content}} when is_binary(content) ->
        content

      _ ->
        nil
    end)
  end

  defp tool_name_matches?(_output, nil), do: true
  defp tool_name_matches?(%{tool_name: tool_name}, tool_name), do: true
  defp tool_name_matches?(%{request: %{tool_name: tool_name}}, tool_name), do: true
  defp tool_name_matches?(_output, _tool_name), do: false

  defp normalize_session(nil), do: {:ok, nil}
  defp normalize_session(%Session{} = session), do: Session.validate(session)

  defp normalize_session(other) do
    {:error,
     Error.validation("evaluation result session must be a Harness.Session or nil",
       source: __MODULE__,
       details: %{session: other}
     )}
  end

  defp normalize_trajectory(nil), do: {:ok, nil}
  defp normalize_trajectory(%Trajectory{} = trajectory), do: Trajectory.validate(trajectory)

  defp normalize_trajectory(other) do
    {:error,
     Error.validation("evaluation result trajectory must be a Trace.Trajectory or nil",
       source: __MODULE__,
       details: %{trajectory: other}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid evaluation result status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_scores(scores) when is_map(scores), do: :ok

  defp validate_scores(scores) do
    {:error,
     Error.validation("evaluation result scores must be a map",
       source: __MODULE__,
       details: %{scores: scores}
     )}
  end

  defp validate_metrics(metrics) when is_map(metrics), do: :ok

  defp validate_metrics(metrics) do
    {:error,
     Error.validation("evaluation result metrics must be a map",
       source: __MODULE__,
       details: %{metrics: metrics}
     )}
  end

  defp validate_failures(failures) when is_list(failures), do: :ok

  defp validate_failures(failures) do
    {:error,
     Error.validation("evaluation result failures must be a list",
       source: __MODULE__,
       details: %{failures: failures}
     )}
  end

  defp validate_outputs(outputs) when is_list(outputs), do: :ok

  defp validate_outputs(outputs) do
    {:error,
     Error.validation("evaluation result outputs must be a list",
       source: __MODULE__,
       details: %{outputs: outputs}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("evaluation result metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
