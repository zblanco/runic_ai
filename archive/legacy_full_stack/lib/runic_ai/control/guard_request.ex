defmodule RunicAI.Control.GuardRequest do
  @moduledoc """
  One guard evaluation request at a named control point.
  """

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Control.GuardPoint
  alias RunicAI.Error
  alias RunicAI.Message
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.ExecutionPlan

  @enforce_keys [:point, :state, :policy, :metadata]
  defstruct [
    :point,
    :state,
    :turn_result,
    :execution_plan,
    :batch_result,
    :candidate_message,
    :subject,
    :policy,
    :metadata
  ]

  @type point :: GuardPoint.t()

  @type t :: %__MODULE__{
          point: point(),
          state: State.t(),
          turn_result: TurnResult.t() | nil,
          execution_plan: ExecutionPlan.t() | nil,
          batch_result: BatchResult.t() | nil,
          candidate_message: Message.t() | nil,
          subject: term(),
          policy: term(),
          metadata: map()
        }

  @spec new(point(), State.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(point, %State{} = state, opts \\ []) when is_atom(point) and is_list(opts) do
    with :ok <- validate_point(point),
         {:ok, state} <- State.validate(state),
         {:ok, turn_result} <- normalize_turn_result(Keyword.get(opts, :turn_result)),
         {:ok, execution_plan} <- normalize_execution_plan(Keyword.get(opts, :execution_plan)),
         {:ok, batch_result} <- normalize_batch_result(Keyword.get(opts, :batch_result)),
         {:ok, candidate_message} <-
           normalize_candidate_message(Keyword.get(opts, :candidate_message)),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         point: point,
         state: state,
         turn_result: turn_result,
         execution_plan: execution_plan,
         batch_result: batch_result,
         candidate_message: candidate_message,
         subject:
           Keyword.get(
             opts,
             :subject,
             infer_subject(turn_result, execution_plan, batch_result, candidate_message)
           ),
         policy: Keyword.get(opts, :policy),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(point(), State.t(), keyword()) :: t()
  def new!(point, %State{} = state, opts \\ []) do
    case new(point, state, opts) do
      {:ok, guard_request} -> guard_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = guard_request) do
    new(guard_request.point, guard_request.state,
      turn_result: guard_request.turn_result,
      execution_plan: guard_request.execution_plan,
      batch_result: guard_request.batch_result,
      candidate_message: guard_request.candidate_message,
      subject: guard_request.subject,
      policy: guard_request.policy,
      metadata: guard_request.metadata
    )
  end

  defp validate_point(point), do: GuardPoint.validate(point)

  defp normalize_turn_result(nil), do: {:ok, nil}
  defp normalize_turn_result(%TurnResult{} = turn_result), do: TurnResult.validate(turn_result)

  defp normalize_turn_result(other) do
    {:error,
     Error.validation("guard turn_result must be a TurnResult or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_execution_plan(nil), do: {:ok, nil}

  defp normalize_execution_plan(%ExecutionPlan{} = execution_plan),
    do: ExecutionPlan.validate(execution_plan)

  defp normalize_execution_plan(other) do
    {:error,
     Error.validation(
       "guard execution_plan must be an ExecutionPlan or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_batch_result(nil), do: {:ok, nil}

  defp normalize_batch_result(%BatchResult{} = batch_result),
    do: BatchResult.validate(batch_result)

  defp normalize_batch_result(other) do
    {:error,
     Error.validation("guard batch_result must be a BatchResult or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp normalize_candidate_message(nil), do: {:ok, nil}

  defp normalize_candidate_message(%Message{} = candidate_message),
    do: Message.validate(candidate_message)

  defp normalize_candidate_message(other) do
    {:error,
     Error.validation(
       "guard candidate_message must be a Message or nil, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("guard request metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp infer_subject(
         _turn_result,
         %ExecutionPlan{} = execution_plan,
         _batch_result,
         _candidate_message
       ),
       do: execution_plan

  defp infer_subject(
         %TurnResult{} = turn_result,
         _execution_plan,
         _batch_result,
         _candidate_message
       ),
       do: turn_result

  defp infer_subject(
         _turn_result,
         _execution_plan,
         %BatchResult{} = batch_result,
         _candidate_message
       ),
       do: batch_result

  defp infer_subject(
         _turn_result,
         _execution_plan,
         _batch_result,
         %Message{} = candidate_message
       ),
       do: candidate_message

  defp infer_subject(_turn_result, _execution_plan, _batch_result, _candidate_message), do: nil
end
