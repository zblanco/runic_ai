defmodule RunicAI.Trace.TraceContractsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Message
  alias RunicAI.Prompt
  alias RunicAI.Trace.CapturePolicy
  alias RunicAI.Trace.Event
  alias RunicAI.Trace.Sink
  alias RunicAI.Trace.Trajectory
  alias RunicAI.Trace.Sinks.InMemory
  alias RunicAI.Trace.Sinks.Telemetry

  test "trajectory append assigns stable trace ids and sequences" do
    trajectory =
      Trajectory.new!(
        id: "trace:phase7",
        recipe: :demo_recipe,
        session_kind: :turn_processor,
        metadata: %{}
      )
      |> Trajectory.append_events!([
        Event.new!(:turn_started, metadata: %{}, input: "hello"),
        Event.new!(:workflow_quiesced, metadata: %{}, status: :ok)
      ])

    assert Enum.map(trajectory.events, &{&1.id, &1.trace_id, &1.sequence, &1.kind}) == [
             {"trace:phase7:1", "trace:phase7", 1, :turn_started},
             {"trace:phase7:2", "trace:phase7", 2, :workflow_quiesced}
           ]
  end

  test "summary capture redacts and truncates prompt payloads" do
    prompt =
      Prompt.new!(
        [
          Message.new!(:user, "supersecret hello"),
          Message.new!(:assistant, "world")
        ],
        metadata: %{api_key: "secret"}
      )

    policy =
      CapturePolicy.new!(
        mode: :summary,
        max_payload_bytes: 10,
        redactor: fn
          %Prompt{} = prompt, :input -> %Prompt{prompt | metadata: %{redacted: true}}
          value, _field -> value
        end
      )

    captured = CapturePolicy.capture(policy, prompt, field: :input)

    assert captured.type == :prompt
    assert captured.metadata == %{redacted: true}
    assert Enum.map(captured.messages, & &1.role) == [:user, :assistant]
    assert hd(captured.messages).content == "superse..."
  end

  test "sink helpers emit to in-memory state and the telemetry bridge" do
    parent = self()
    handler_id = "phase7-trace-#{System.unique_integer([:positive])}"
    event_name = [:phase7, :trace, :turn_completed]

    :telemetry.attach(
      handler_id,
      event_name,
      fn received_name, measurements, metadata, _config ->
        send(parent, {:telemetry, received_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    event =
      Event.new!(
        :turn_completed,
        metadata: %{},
        status: :reply,
        measurements: %{elapsed_ms: 12}
      )

    sinks =
      Sink.normalize_input!([
        InMemory,
        {Telemetry, [prefix: [:phase7, :trace]]}
      ])

    assert {:ok, updated_sinks} = Sink.emit_all(sinks, event)

    assert_receive {:telemetry, ^event_name, %{count: 1, elapsed_ms: 12},
                    %{event: received_event, status: :reply}}

    assert received_event == event

    in_memory_events =
      updated_sinks
      |> Enum.find_value(fn
        %{module: InMemory, state: state} -> InMemory.events(state)
        _other -> nil
      end)

    assert in_memory_events == [event]
  end
end
