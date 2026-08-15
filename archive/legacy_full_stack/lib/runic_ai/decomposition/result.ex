defmodule RunicAI.Decomposition.Result do
  @moduledoc """
  Normalized child execution result.
  """

  alias RunicAI.Agent.State
  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  @valid_statuses [:completed, :failed, :review, :wait, :handoff, :cancelled]

  @enforce_keys [:task_id, :status, :artifacts, :metadata]
  defstruct [
    :task_id,
    :status,
    :output,
    :artifacts,
    :error,
    :review_request,
    :wait,
    :handoff,
    :child_state,
    :metadata
  ]

  @type status :: :completed | :failed | :review | :wait | :handoff | :cancelled

  @type t :: %__MODULE__{
          task_id: String.t(),
          status: status(),
          output: term(),
          artifacts: [term()],
          error: Error.t() | nil,
          review_request: ReviewRequest.t() | nil,
          wait: Wait.t() | nil,
          handoff: HandoffArtifact.t() | nil,
          child_state: State.t() | nil | term(),
          metadata: map()
        }

  @spec new(String.t(), status(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(task_id, status, opts \\ []) when is_list(opts) do
    artifacts = Keyword.get(opts, :artifacts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_task_id(task_id),
         :ok <- validate_status(status),
         :ok <- validate_artifacts(artifacts),
         {:ok, error} <- normalize_error(Keyword.get(opts, :error)),
         {:ok, review_request} <- normalize_review_request(Keyword.get(opts, :review_request)),
         {:ok, wait} <- normalize_wait(Keyword.get(opts, :wait)),
         {:ok, handoff} <- normalize_handoff(Keyword.get(opts, :handoff)),
         {:ok, child_state} <- normalize_child_state(Keyword.get(opts, :child_state)),
         :ok <- validate_requirements(status, error, review_request, wait, handoff),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         task_id: task_id,
         status: status,
         output: Keyword.get(opts, :output),
         artifacts: artifacts,
         error: error,
         review_request: review_request,
         wait: wait,
         handoff: handoff,
         child_state: child_state,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), status(), keyword()) :: t()
  def new!(task_id, status, opts \\ []) do
    case new(task_id, status, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    new(result.task_id, result.status,
      output: result.output,
      artifacts: result.artifacts,
      error: result.error,
      review_request: result.review_request,
      wait: result.wait,
      handoff: result.handoff,
      child_state: result.child_state,
      metadata: result.metadata
    )
  end

  @spec from_input(t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = result), do: validate(result)

  def from_input(input) when is_map(input) do
    new(map_get(input, :task_id), map_get(input, :status),
      output: map_get(input, :output),
      artifacts: map_get(input, :artifacts) || [],
      error: map_get(input, :error),
      review_request: map_get(input, :review_request),
      wait: map_get(input, :wait),
      handoff: map_get(input, :handoff),
      child_state: map_get(input, :child_state),
      metadata: map_get(input, :metadata) || %{}
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Decomposition.Result-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | map()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec completed(String.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def completed(task_id, output, opts \\ []) do
    new(task_id, :completed,
      output: output,
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec completed!(String.t(), term(), keyword()) :: t()
  def completed!(task_id, output, opts \\ []) do
    case completed(task_id, output, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec failed(String.t(), Error.t() | term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def failed(task_id, error_or_reason, opts \\ [])

  def failed(task_id, %Error{} = error, opts) do
    new(task_id, :failed,
      error: error,
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def failed(task_id, reason, opts) do
    failed(task_id, Error.from_reason(reason, source: __MODULE__), opts)
  end

  @spec failed!(String.t(), Error.t() | term(), keyword()) :: t()
  def failed!(task_id, error_or_reason, opts \\ []) do
    case failed(task_id, error_or_reason, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec review(String.t(), ReviewRequest.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def review(task_id, %ReviewRequest{} = review_request, opts \\ []) do
    new(task_id, :review,
      review_request: review_request,
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec review!(String.t(), ReviewRequest.t(), keyword()) :: t()
  def review!(task_id, %ReviewRequest{} = review_request, opts \\ []) do
    case review(task_id, review_request, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec wait(String.t(), Wait.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def wait(task_id, %Wait{} = wait, opts \\ []) do
    new(task_id, :wait,
      wait: wait,
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec wait!(String.t(), Wait.t(), keyword()) :: t()
  def wait!(task_id, %Wait{} = wait, opts \\ []) do
    case wait(task_id, wait, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec handoff(String.t(), HandoffArtifact.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def handoff(task_id, %HandoffArtifact{} = handoff, opts \\ []) do
    new(task_id, :handoff,
      handoff: handoff,
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec handoff!(String.t(), HandoffArtifact.t(), keyword()) :: t()
  def handoff!(task_id, %HandoffArtifact{} = handoff, opts \\ []) do
    case handoff(task_id, handoff, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec cancelled(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def cancelled(task_id, opts \\ []) do
    new(task_id, :cancelled,
      output: Keyword.get(opts, :output),
      artifacts: Keyword.get(opts, :artifacts, []),
      child_state: Keyword.get(opts, :child_state),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec cancelled!(String.t(), keyword()) :: t()
  def cancelled!(task_id, opts \\ []) do
    case cancelled(task_id, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true
  def completed?(%__MODULE__{}), do: false

  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: :failed}), do: true
  def failed?(%__MODULE__{}), do: false

  defp validate_task_id(task_id) when is_binary(task_id) and task_id != "", do: :ok

  defp validate_task_id(task_id) do
    {:error,
     Error.validation("decomposition result task_id must be a non-empty string",
       source: __MODULE__,
       details: %{task_id: task_id}
     )}
  end

  defp validate_status(status) when status in @valid_statuses, do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("invalid decomposition result status: #{inspect(status)}",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @valid_statuses}
     )}
  end

  defp validate_artifacts(artifacts) when is_list(artifacts), do: :ok

  defp validate_artifacts(artifacts) do
    {:error,
     Error.validation("decomposition result artifacts must be a list",
       source: __MODULE__,
       details: %{artifacts: artifacts}
     )}
  end

  defp normalize_error(nil), do: {:ok, nil}
  defp normalize_error(%Error{} = error), do: {:ok, error}

  defp normalize_error(error) do
    {:error,
     Error.validation("decomposition result error must be a RunicAI.Error or nil",
       source: __MODULE__,
       details: %{error: error}
     )}
  end

  defp normalize_review_request(nil), do: {:ok, nil}

  defp normalize_review_request(%ReviewRequest{} = review_request),
    do: ReviewRequest.validate(review_request)

  defp normalize_review_request(review_request) do
    {:error,
     Error.validation("decomposition result review_request must be a ReviewRequest or nil",
       source: __MODULE__,
       details: %{review_request: review_request}
     )}
  end

  defp normalize_wait(nil), do: {:ok, nil}
  defp normalize_wait(%Wait{} = wait), do: Wait.validate(wait)

  defp normalize_wait(wait) do
    {:error,
     Error.validation("decomposition result wait must be a Wait or nil",
       source: __MODULE__,
       details: %{wait: wait}
     )}
  end

  defp normalize_handoff(nil), do: {:ok, nil}
  defp normalize_handoff(%HandoffArtifact{} = handoff), do: HandoffArtifact.validate(handoff)

  defp normalize_handoff(handoff) do
    {:error,
     Error.validation("decomposition result handoff must be a HandoffArtifact or nil",
       source: __MODULE__,
       details: %{handoff: handoff}
     )}
  end

  defp normalize_child_state(nil), do: {:ok, nil}
  defp normalize_child_state(%State{} = state), do: State.validate(state)
  defp normalize_child_state(child_state), do: {:ok, child_state}

  defp validate_requirements(:failed, nil, _review_request, _wait, _handoff) do
    {:error,
     Error.validation("failed decomposition results require an error", source: __MODULE__)}
  end

  defp validate_requirements(:review, _error, nil, _wait, _handoff) do
    {:error,
     Error.validation("review decomposition results require a review_request",
       source: __MODULE__
     )}
  end

  defp validate_requirements(:wait, _error, _review_request, nil, _handoff) do
    {:error,
     Error.validation("wait decomposition results require a wait payload", source: __MODULE__)}
  end

  defp validate_requirements(:handoff, _error, _review_request, _wait, nil) do
    {:error,
     Error.validation("handoff decomposition results require a handoff artifact",
       source: __MODULE__
     )}
  end

  defp validate_requirements(_status, _error, _review_request, _wait, _handoff), do: :ok

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition result metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp map_get(input, key) when is_map(input) and is_atom(key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end
end
