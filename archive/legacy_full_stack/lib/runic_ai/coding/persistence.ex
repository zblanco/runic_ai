defmodule RunicAI.Coding.Persistence do
  @moduledoc """
  Optional persistence behaviour for coding harness sessions.

  Core coding tools do not require durable storage. Harnesses that want durable
  evidence can provide `{module, handle}` as `Workspace.persistence` and
  implement this behaviour.
  """

  alias RunicAI.Error

  @type handle :: term()
  @type artifact_ref :: String.t()

  @callback put_artifact(handle(), map()) :: {:ok, artifact_ref()} | {:error, term()}
  @callback get_artifact(handle(), artifact_ref()) :: {:ok, map()} | {:error, term()}
  @callback record_event(handle(), map()) :: :ok | {:error, term()}

  @spec put_artifact(nil | {module(), handle()} | module(), map()) ::
          {:ok, artifact_ref() | nil} | {:error, Error.t()}
  def put_artifact(nil, _artifact), do: {:ok, nil}

  def put_artifact({module, handle}, artifact) when is_atom(module) and is_map(artifact) do
    normalize_result(module.put_artifact(handle, artifact), module)
  end

  def put_artifact(module, artifact) when is_atom(module) and is_map(artifact) do
    normalize_result(module.put_artifact(nil, artifact), module)
  end

  @spec get_artifact(nil | {module(), handle()} | module(), artifact_ref()) ::
          {:ok, map() | nil} | {:error, Error.t()}
  def get_artifact(nil, _ref), do: {:ok, nil}

  def get_artifact({module, handle}, ref) when is_atom(module) and is_binary(ref) do
    normalize_result(module.get_artifact(handle, ref), module)
  end

  def get_artifact(module, ref) when is_atom(module) and is_binary(ref) do
    normalize_result(module.get_artifact(nil, ref), module)
  end

  @spec record_event(nil | {module(), handle()} | module(), map()) :: :ok | {:error, Error.t()}
  def record_event(nil, _event), do: :ok

  def record_event({module, handle}, event) when is_atom(module) and is_map(event) do
    normalize_record_result(module.record_event(handle, event), module)
  end

  def record_event(module, event) when is_atom(module) and is_map(event) do
    normalize_record_result(module.record_event(nil, event), module)
  end

  defp normalize_result({:ok, value}, _module), do: {:ok, value}

  defp normalize_result({:error, reason}, module) do
    {:error,
     Error.from_reason(reason,
       kind: :persistence,
       message: "coding persistence operation failed",
       source: module
     )}
  end

  defp normalize_result(other, module) do
    {:error,
     Error.from_reason(other,
       kind: :persistence,
       message: "unexpected coding persistence response",
       source: module
     )}
  end

  defp normalize_record_result(:ok, _module), do: :ok

  defp normalize_record_result({:error, reason}, module) do
    {:error,
     Error.from_reason(reason,
       kind: :persistence,
       message: "coding persistence event record failed",
       source: module
     )}
  end

  defp normalize_record_result(other, module) do
    {:error,
     Error.from_reason(other,
       kind: :persistence,
       message: "unexpected coding persistence event response",
       source: module
     )}
  end
end
