defmodule RunicAI.Steps.NormalizeResumeSignal do
  @moduledoc """
  Validate a resume signal against a pending wait.
  """

  require Runic

  alias RunicAI.Error
  alias RunicAI.ResumeSignal
  alias RunicAI.Wait

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :normalize_resume_signal)

    Runic.step(
      fn %Wait{} = wait, %ResumeSignal{} = resume_signal ->
        normalize!(wait, resume_signal)
      end,
      name: name
    )
  end

  @spec normalize(Wait.t(), ResumeSignal.t()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(%Wait{} = wait, %ResumeSignal{} = resume_signal) do
    with {:ok, wait} <- Wait.validate(wait),
         {:ok, resume_signal} <- ResumeSignal.validate(resume_signal),
         :ok <- validate_resume_key(wait, resume_signal) do
      {:ok, resume_signal.payload}
    end
  end

  @spec normalize!(Wait.t(), ResumeSignal.t()) :: term()
  def normalize!(%Wait{} = wait, %ResumeSignal{} = resume_signal) do
    case normalize(wait, resume_signal) do
      {:ok, payload} -> payload
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_resume_key(%Wait{resume_key: resume_key}, %ResumeSignal{resume_key: resume_key}),
    do: :ok

  defp validate_resume_key(%Wait{} = wait, %ResumeSignal{} = resume_signal) do
    {:error,
     Error.validation("resume signal resume_key did not match the wait",
       source: __MODULE__,
       details: %{wait: wait.resume_key, signal: resume_signal.resume_key}
     )}
  end
end
