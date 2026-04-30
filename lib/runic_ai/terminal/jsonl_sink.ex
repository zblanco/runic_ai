defmodule RunicAI.Terminal.JsonlSink do
  @moduledoc """
  Small process-free JSONL sink for terminal events.
  """

  alias RunicAI.Error
  alias RunicAI.Terminal.Event

  @type t :: nil | File.io_device()

  @spec open(nil | Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def open(nil), do: {:ok, nil}

  def open(path) when is_binary(path) and path != "" do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, device} <- File.open(path, [:write, :utf8]) do
      {:ok, device}
    else
      {:error, reason} ->
        {:error,
         Error.validation("could not open terminal JSONL sink",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  def open(path) do
    {:error,
     Error.validation("terminal JSONL path must be a non-empty string or nil",
       source: __MODULE__,
       details: %{path: path}
     )}
  end

  @spec write_event(t(), Event.t()) :: :ok | {:error, Error.t()}
  def write_event(nil, %Event{}), do: :ok

  def write_event(device, %Event{} = event) do
    line =
      event
      |> Event.to_json_map()
      |> Jason.encode!()

    case IO.write(device, line <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.unexpected("could not write terminal JSONL event",
           source: __MODULE__,
           details: %{reason: reason}
         )}
    end
  end

  @spec close(t()) :: :ok
  def close(nil), do: :ok
  def close(device), do: File.close(device)
end
