defmodule RunicAI.Browser.Session do
  @moduledoc """
  Supervised browser session process used by model-visible browser tools.
  """

  use GenServer

  alias RunicAI.Browser.Backends.Fake
  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Error
  alias RunicAI.Trace.Event

  @default_timeout_ms 120_000

  @type t :: pid() | atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec navigate(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def navigate(session, url, args \\ %{}, opts \\ []),
    do: call(session, {:navigate, url, args}, opts)

  @spec snapshot(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(session, args \\ %{}, opts \\ []), do: call(session, {:snapshot, args}, opts)

  @spec click(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def click(session, selector, args \\ %{}, opts \\ []),
    do: call(session, {:click, selector, args}, opts)

  @spec type(t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def type(session, selector, text, args \\ %{}, opts \\ []),
    do: call(session, {:type, selector, text, args}, opts)

  @spec press(t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def press(session, key, args \\ %{}, opts \\ []), do: call(session, {:press, key, args}, opts)

  @spec scroll(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def scroll(session, args \\ %{}, opts \\ []), do: call(session, {:scroll, args}, opts)

  @spec console(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def console(session, args \\ %{}, opts \\ []), do: call(session, {:console, args}, opts)

  @spec screenshot(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def screenshot(session, args \\ %{}, opts \\ []), do: call(session, {:screenshot, args}, opts)

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, Fake)
    backend_opts = Keyword.get(opts, :backend_opts, opts)
    timeout_ms = Keyword.get(opts, :inactivity_timeout_ms, @default_timeout_ms)

    with {:ok, backend_state} <- backend.init(backend_opts) do
      timer = schedule_timeout(timeout_ms)

      {:ok,
       %{
         backend: backend,
         backend_state: backend_state,
         event_sink: Keyword.get(opts, :event_sink),
         inactivity_timeout_ms: timeout_ms,
         timer: timer,
         last_observation: nil
       }}
    end
  end

  @impl true
  def handle_call({:browser_request, request, opts}, _from, state) do
    state = refresh_timer(state)
    event_sink = Keyword.get(opts, :event_sink) || state.event_sink
    started_mono = System.monotonic_time(:millisecond)
    operation = operation_name(request)

    emit_browser_event(event_sink, :browser_operation_started, :running, operation, request, %{})

    with {:ok, backend_state, observation} <- dispatch(request, state) do
      normalized = normalize_observation(observation)

      emit_browser_event(
        event_sink,
        :browser_operation_completed,
        Map.get(normalized, :status, :ok),
        operation,
        request,
        Map.put(summarize_observation(normalized), :duration_ms, elapsed_ms(started_mono))
      )

      {:reply, {:ok, normalized},
       %{state | backend_state: backend_state, last_observation: normalized}}
    else
      {:error, %Error{} = error} ->
        emit_browser_event(event_sink, :browser_operation_failed, :error, operation, request, %{
          duration_ms: elapsed_ms(started_mono),
          error: error.message,
          details: error.details
        })

        {:reply, {:error, error}, state}

      {:error, reason} ->
        error = Error.from_reason(reason, source: __MODULE__)

        emit_browser_event(event_sink, :browser_operation_failed, :error, operation, request, %{
          duration_ms: elapsed_ms(started_mono),
          error: error.message,
          details: error.details
        })

        {:reply, {:error, error}, state}
    end
  end

  def handle_call(request, from, state),
    do: handle_call({:browser_request, request, []}, from, state)

  @impl true
  def handle_info(:inactivity_timeout, state) do
    _ = state.backend.close(state.backend_state)
    {:stop, :normal, state}
  end

  defp call(session, request, opts) do
    GenServer.call(session, {:browser_request, request, opts}, :infinity)
  catch
    :exit, reason -> {:error, Error.from_reason(reason, source: __MODULE__)}
  end

  defp dispatch({:navigate, url, args}, state),
    do: state.backend.navigate(state.backend_state, url, args)

  defp dispatch({:snapshot, args}, state), do: state.backend.snapshot(state.backend_state, args)

  defp dispatch({:click, selector, args}, state),
    do: state.backend.click(state.backend_state, selector, args)

  defp dispatch({:type, selector, text, args}, state),
    do: state.backend.type(state.backend_state, selector, text, args)

  defp dispatch({:press, key, args}, state),
    do: state.backend.press(state.backend_state, key, args)

  defp dispatch({:scroll, args}, state), do: state.backend.scroll(state.backend_state, args)
  defp dispatch({:console, args}, state), do: state.backend.console(state.backend_state, args)

  defp dispatch({:screenshot, args}, state),
    do: state.backend.screenshot(state.backend_state, args)

  defp operation_name({:navigate, _url, _args}), do: :navigate
  defp operation_name({:snapshot, _args}), do: :snapshot
  defp operation_name({:click, _selector, _args}), do: :click
  defp operation_name({:type, _selector, _text, _args}), do: :type
  defp operation_name({:press, _key, _args}), do: :press
  defp operation_name({:scroll, _args}), do: :scroll
  defp operation_name({:console, _args}), do: :console
  defp operation_name({:screenshot, _args}), do: :screenshot
  defp operation_name(_request), do: :unknown

  defp request_summary({:navigate, url, _args}), do: %{url: url}
  defp request_summary({:snapshot, _args}), do: %{}
  defp request_summary({:click, selector, _args}), do: %{selector: selector}

  defp request_summary({:type, selector, text, _args}),
    do: %{selector: selector, text_bytes: byte_size(text)}

  defp request_summary({:press, key, _args}), do: %{key: key}

  defp request_summary({:scroll, args}),
    do: Map.take(args, [:direction, :amount, "direction", "amount"])

  defp request_summary({:console, args}), do: Map.take(args, [:limit, "limit"])
  defp request_summary({:screenshot, args}), do: Map.take(args, [:path, "path"])
  defp request_summary(_request), do: %{}

  defp summarize_observation(observation) when is_map(observation) do
    %{
      action: Map.get(observation, :action),
      url: Map.get(observation, :url),
      title: Map.get(observation, :title),
      selector: Map.get(observation, :selector),
      key: Map.get(observation, :key),
      direction: Map.get(observation, :direction),
      path: Map.get(observation, :path),
      media_type: Map.get(observation, :media_type),
      image_byte_size: Map.get(observation, :byte_size),
      console_count: Map.get(observation, :console_count, Map.get(observation, :count)),
      refs_count: observation |> Map.get(:refs, %{}) |> map_size(),
      snapshot_preview:
        observation |> Map.get(:snapshot, "") |> to_string() |> String.slice(0, 1_000)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp summarize_observation(_observation), do: %{}

  defp elapsed_ms(started_mono), do: System.monotonic_time(:millisecond) - started_mono

  defp emit_browser_event(event_sink, kind, status, operation, request, output)
       when is_function(event_sink, 1) do
    event =
      Event.new!(kind,
        status: status,
        output: TraceRedactor.redact(Map.merge(request_summary(request), output)),
        metadata: %{
          browser?: true,
          live?: true,
          source: :browser_session,
          operation: operation
        },
        observed_at: DateTime.utc_now()
      )

    event_sink.(event)
  rescue
    _exception -> :ok
  end

  defp emit_browser_event(_event_sink, _kind, _status, _operation, _request, _output), do: :ok

  defp normalize_observation(observation) when is_map(observation) do
    observation
    |> Map.put_new(:observed_at, DateTime.utc_now())
    |> Map.put_new(:backend_normalized?, true)
  end

  defp refresh_timer(%{timer: timer, inactivity_timeout_ms: timeout_ms} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %{state | timer: schedule_timeout(timeout_ms)}
  end

  defp schedule_timeout(:infinity), do: nil

  defp schedule_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: Process.send_after(self(), :inactivity_timeout, timeout_ms)
end
