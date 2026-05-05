defmodule RunicAI.Terminal.ExRatatui.WorkbenchTest do
  use ExUnit.Case, async: false

  require Logger

  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse
  alias ExRatatui.Frame
  alias ExRatatui.Runtime
  alias RunicAI.Persistence.ManagedWorkflows
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite
  alias RunicAI.RLM.Episode
  alias RunicAI.Terminal.ExRatatui.App
  alias RunicAI.Terminal.ExRatatui.Commands
  alias RunicAI.Terminal.ExRatatui.CommandSuggestions
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Options
  alias RunicAI.Terminal.ExRatatui.RenderCache
  alias RunicAI.Terminal.ExRatatui.SlashCommands
  alias RunicAI.Terminal.ExRatatui.Update
  alias RunicAI.Terminal.ExRatatui.Views.Conversation
  alias RunicAI.Terminal.ExRatatui.Views.Details
  alias RunicAI.Terminal.ExRatatui.Views.Logs
  alias RunicAI.Terminal.ExRatatui.Views.ReviewModal
  alias RunicAI.Terminal.ExRatatui.Views.Root
  alias RunicAI.Terminal.ExRatatui.Views.Timeline
  alias RunicAI.Terminal.MarkdownBlocks
  alias RunicAI.Terminal.StreamBuffer
  alias RunicAI.Terminal.Syntax

  setup do
    {:ok, store} = SQLite.open(":memory:")
    seed_store(store)
    on_exit(fn -> SQLite.close(store) end)
    {:ok, store: store}
  end

  test "loads a durable workbench snapshot from SQLite", %{store: store} do
    model = model(store)

    assert {:ok, snapshot} = Commands.load_snapshot(model)

    assert [%{id: "run:test"}] = snapshot.runs
    assert length(snapshot.timeline) >= 6
    assert snapshot.messages != []
    assert snapshot.runnable_events != []
    assert snapshot.tool_calls != []
    assert snapshot.artifacts != []
    assert snapshot.scorecards != []
    assert snapshot.repairs != []
    assert [%{status: "pending"}] = snapshot.review_requests
    assert snapshot.managed_workflows != []
    assert snapshot.eval_cohort != []
    assert snapshot.signal_views.session_recall != []
  end

  test "supports search, export, review decisions, managed filters, and eval cohorts", %{
    store: store
  } do
    model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))

    assert {:ok, search} = Commands.search(model, "dangerous")
    assert Enum.any?(search.search_results, &(&1.kind == "hitl"))

    export_path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-tui-export-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(export_path) end)

    assert {:ok, export} = Commands.export_run(model, export_path)
    assert export.last_export_path == export_path
    assert File.exists?(export_path)

    assert {:ok, after_review} = Commands.apply_review_decision(model, "approve")
    assert [%{status: "approved"}] = after_review.review_requests

    assert {:ok, managed} = Commands.managed_workflows(model, "paused")
    assert [%{workflow_key: "nightly-agent"}] = managed.managed_workflows

    assert {:ok, evals} = Commands.eval_cohort(model, "objective_satisfied")
    assert [%{objective_status: "objective_satisfied"}] = evals.eval_cohort
  end

  test "slash command parser covers workbench commands" do
    assert {:ok, {:chat}} = SlashCommands.parse("/chat")
    assert {:ok, {:debug}} = SlashCommands.parse("/debug")
    assert {:ok, {:search, "dangerous"}} = SlashCommands.parse("/search dangerous")
    assert {:ok, {:managed, "paused"}} = SlashCommands.parse("/managed paused")
    assert {:ok, {:start, "nightly-agent"}} = SlashCommands.parse("/start nightly-agent")
    assert {:ok, {:resume, "nightly-agent"}} = SlashCommands.parse("/resume nightly-agent")

    assert {:ok, {:eval, "objective_satisfied"}} =
             SlashCommands.parse("/eval objective_satisfied")

    assert {:ok, {:export, nil}} = SlashCommands.parse("/export")
    assert {:ok, {:logs, "error"}} = SlashCommands.parse("/logs error")
    assert {:ok, {:logs, "source:agent"}} = SlashCommands.parse("/logs source:agent")
    assert {:ok, {:prompt}} = SlashCommands.parse("/prompt")
    assert {:error, _reason} = SlashCommands.parse("/wat")
  end

  test "headless ExRatatui app hydrates and handles events", %{store: store} do
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)

    snapshot = Runtime.snapshot(pid)
    assert snapshot.mode == :reducer
    assert snapshot.polling_enabled? == false
    assert snapshot.render_count >= 1

    state = :sys.get_state(pid).user_state
    assert %Model{} = state
    assert state.view_mode == :chat
    assert state.focus == :conversation
    assert state.runs != []

    :ok = Runtime.inject_event(pid, %Key{code: "tab", kind: "press"})
    Process.sleep(50)

    assert :sys.get_state(pid).user_state.focus == :composer

    :ok = Runtime.inject_event(pid, %Key{code: "f2", kind: "press"})
    assert eventually(fn -> :sys.get_state(pid).user_state.view_mode == :debug end)
    assert :sys.get_state(pid).user_state.focus == :composer

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "conversation scroll keys and mouse wheel update row scrollback", %{store: store} do
    model = %{model(store) | focus: :conversation, view_mode: :chat}

    assert {:noreply, scrolled} =
             Update.update({:event, %Key{code: "page_up", kind: "press"}}, model)

    assert scrolled.conversation_scrollback_rows == 12
    assert scrolled.status_message == "conversation: 12 rows back"

    assert {:noreply, scrolled} =
             Update.update({:event, %Mouse{kind: "scroll_down"}}, scrolled)

    assert scrolled.conversation_scrollback_rows == 11

    assert {:noreply, at_tail} =
             Update.update({:event, %Key{code: "end", kind: "press"}}, scrolled)

    assert at_tail.conversation_scrollback_rows == 0
    assert at_tail.status_message == "conversation: tail"

    assert {:noreply, at_top} =
             Update.update({:event, %Key{code: "home", kind: "press"}}, at_tail)

    assert at_top.conversation_scrollback_rows > 100_000
    assert at_top.status_message == "conversation: top"
  end

  test "chat layout keeps the conversation full width above composer", %{store: store} do
    model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))
    frame = %Frame{width: 120, height: 40}

    widgets = Root.render(model, frame)

    assert {_status, %{x: 0, y: 0, width: 120, height: 1}} = Enum.at(widgets, 0)
    assert {summary, %{x: 0, y: 1, width: 120, height: 1}} = Enum.at(widgets, 1)
    assert summary.text =~ "thread="
    assert summary.text =~ "msgs="

    assert {%ExRatatui.Widgets.WidgetList{} = conversation, conversation_area} =
             Enum.find(widgets, fn
               {%ExRatatui.Widgets.WidgetList{}, _area} -> true
               _other -> false
             end)

    assert conversation.block.title =~ "Conversation"
    assert conversation_area.x == 0
    assert conversation_area.width == 120

    refute Enum.any?(widgets, fn
             {%ExRatatui.Widgets.Paragraph{block: %{title: "Agent Activity"}}, _area} -> true
             {%ExRatatui.Widgets.Paragraph{block: %{title: "Logs"}}, _area} -> true
             _other -> false
           end)
  end

  test "chat and debug layouts stay coherent across narrow wide and plain snapshots", %{
    store: store
  } do
    base_model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))

    cases = [
      {:chat, :runic, 80, 24},
      {:chat, :runic, 100, 30},
      {:chat, :runic, 160, 40},
      {:debug, :plain, 100, 30}
    ]

    for {view_mode, theme, width, height} <- cases do
      model = %{base_model | view_mode: view_mode, theme: theme}
      widgets = Root.render(model, %Frame{width: width, height: height})

      assert widgets != []

      assert Enum.all?(widgets, fn {_widget, area} ->
               area.x >= 0 and area.y >= 0 and area.width > 0 and area.height > 0 and
                 area.x + area.width <= width and area.y + area.height <= height
             end)

      assert Enum.any?(widgets, fn
               {%ExRatatui.Widgets.Textarea{}, _area} -> true
               _other -> false
             end)
    end
  end

  test "NO_COLOR defaults the TUI theme to plain unless explicitly overridden" do
    old_no_color = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "1")

    on_exit(fn ->
      case old_no_color do
        nil -> System.delete_env("NO_COLOR")
        value -> System.put_env("NO_COLOR", value)
      end
    end)

    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])
    assert options.theme == :plain

    {:ok, options} =
      Options.parse(["--cwd", tmp_dir(), "--persistence", "memory", "--theme", "runic"])

    assert options.theme == :runic
  end

  test "composer up and down keys navigate submitted prompt history", %{store: store} do
    model =
      store
      |> model()
      |> Map.put(:focus, :composer)
      |> Model.remember_composer_submission("first prompt")
      |> Model.remember_composer_submission("second prompt")

    assert {:noreply, model} =
             Update.update({:event, %Key{code: "up", kind: "press"}}, model)

    assert model.composer_text == "second prompt"
    assert model.composer_history_index == 1

    assert {:noreply, model} =
             Update.update({:event, %Key{code: "up", kind: "press"}}, model)

    assert model.composer_text == "first prompt"
    assert model.composer_history_index == 0

    assert {:noreply, model} =
             Update.update({:event, %Key{code: "down", kind: "press"}}, model)

    assert model.composer_text == "second prompt"
    assert model.composer_history_index == 1

    assert {:noreply, model} =
             Update.update({:event, %Key{code: "down", kind: "press"}}, model)

    assert model.composer_text == ""
    assert model.composer_history_index == nil
  end

  test "composer defers enter submit so pasted multiline prompts stay together", %{store: store} do
    composer_ref = ExRatatui.textarea_new()

    model =
      store
      |> model()
      |> Map.put(:focus, :composer)
      |> Map.put(:composer_ref, composer_ref)

    :ok = ExRatatui.textarea_set_value(composer_ref, "first line")

    assert {:noreply, model, commands: [%ExRatatui.Command{} = command]} =
             Update.update({:event, %Key{code: "enter", kind: "press"}}, model)

    assert command.kind == :after
    assert {:deferred_composer_submit, submit_id} = command.message
    assert model.pending_composer_submit_id == submit_id

    assert {:noreply, model} =
             Update.update({:event, %Key{code: "s", kind: "press"}}, model)

    assert model.pending_composer_submit_id == nil
    assert ExRatatui.textarea_get_value(composer_ref) == "first line\ns"

    assert {:noreply, model} =
             Update.update({:info, {:deferred_composer_submit, submit_id}}, model)

    assert model.active_run? == false

    :ok = ExRatatui.textarea_set_value(composer_ref, "first line\nsecond line")

    assert {:noreply, model, commands: [%ExRatatui.Command{} = command]} =
             Update.update({:event, %Key{code: "enter", kind: "press"}}, model)

    assert {:deferred_composer_submit, submit_id} = command.message

    assert {:noreply, submitted, commands: [%ExRatatui.Command{kind: :async}]} =
             Update.update({:info, {:deferred_composer_submit, submit_id}}, model)

    assert submitted.active_run? == true
    assert submitted.composer_text == ""
    assert ExRatatui.textarea_get_value(composer_ref) == ""
  end

  test "live objective submission writes through to the same SQLite store", %{store: store} do
    run_fun = fn _cwd, _objective, opts ->
      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :node_started,
        status: :running,
        data: %{
          runnable: %{
            id: "runnable:tui",
            node: "assistant_node_1_plan",
            component_id: "plan",
            component_type: "blueprint_proposer"
          },
          input: %{objective: "from tui"}
        }
      })

      {:ok, assistant_result()}
    end

    model = %{model(store) | run_fun: run_fun}

    assert {:ok, snapshot} = Commands.start_agent_run(model, "from tui")
    run_id = snapshot.selected_run_id

    assert Queries.run_timeline(store, run_id) != []
    assert length(snapshot.timeline) == length(Queries.run_timeline(store, run_id))
    assert Queries.runnable_events(store, run_id) != []
  end

  test "composer submissions keep a stable TUI session and pass prior conversation history", %{
    store: store
  } do
    now = DateTime.utc_now()

    record!(store, %{
      id: "event:prior-user",
      at: DateTime.add(now, -2, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :message,
      phase: :user,
      status: :ok,
      title: "User request",
      detail: "Write the outline.",
      data: %{
        run_id: "run:test",
        role: "user",
        message_kind: "objective",
        content: "Write the outline."
      }
    })

    record!(store, %{
      id: "event:prior-outline",
      at: DateTime.add(now, -1, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :rlm_plan,
      phase: :direct_response_completed,
      status: :ok,
      title: "Direct response completed",
      detail: "Outline ready",
      data: %{
        run_id: "run:test",
        data: %{
          reply_text: "Outline: a piano, a spiteful path god, and a lucky cursed hero.",
          output: %{text_preview: "Outline: a piano, a spiteful path god"}
        }
      }
    })

    caller = self()

    run_fun = fn _cwd, objective, opts ->
      send(
        caller,
        {:submitted_with_history, objective, opts[:session_id], opts[:run_id],
         opts[:conversation_history]}
      )

      {:ok, assistant_result()}
    end

    model = model(store)
    {:ok, loaded} = Commands.load_snapshot(model)

    model =
      model
      |> Model.apply_snapshot(loaded)
      |> Map.put(:run_fun, run_fun)

    assert {:ok, snapshot} = Commands.start_agent_run(model, "Now write the full story.")

    assert_receive {:submitted_with_history, "Now write the full story.", "session:test", run_id,
                    history}

    assert run_id != "session:test"
    assert run_id != "run:test"
    assert snapshot.session_id == "session:test"
    assert snapshot.selected_run_id == run_id
    assert Enum.any?(history, &(&1.content =~ "spiteful path god"))
    refute Enum.any?(history, &(&1.content =~ "Now write the full story."))

    assert Enum.any?(snapshot.messages, &(&1.content =~ "spiteful path god"))
    assert Enum.any?(snapshot.messages, &(&1.content == "Now write the full story."))
  end

  test "live direct response submission exposes assistant messages", %{store: store} do
    run_fun = fn _cwd, _objective, opts ->
      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :direct_response_completed,
        status: :ok,
        data: %{
          reply_text: "Visible direct response",
          output: %{text_preview: "Visible direct response"}
        }
      })

      {:ok,
       assistant_result()
       |> Map.put(:direct_response?, true)
       |> Map.put(:output, %{text: "Visible direct response"})
       |> Map.put(:artifacts, [])}
    end

    model = %{model(store) | run_fun: run_fun}

    assert {:ok, snapshot} = Commands.start_agent_run(model, "Write me a poem about frogs")

    assert Enum.any?(
             snapshot.messages,
             &(&1.message_kind == "direct_response" and &1.content == "Visible direct response")
           )

    assert Enum.any?(
             snapshot.messages,
             &(&1.role == "user" and &1.message_kind == "objective" and
                 &1.content == "Write me a poem about frogs")
           )
  end

  test "live RLM submissions expose completed workflow output in the conversation", %{
    store: store
  } do
    caller = self()

    run_fun = fn _cwd, _objective, opts ->
      send(caller, {:rlm_submission, opts[:session_id], opts[:run_id]})

      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :proposal_received,
        status: :ok,
        data: %{message: "proposal ready"}
      })

      {:ok, rlm_result("Three selected repos: runic_ai, compendium, libbit.")}
    end

    model = model(store)
    {:ok, loaded} = Commands.load_snapshot(model)

    model =
      model
      |> Model.apply_snapshot(loaded)
      |> Map.merge(%{agent: :rlm, run_fun: run_fun})

    assert {:ok, snapshot} = Commands.start_agent_run(model, "Pick three repos")
    assert_receive {:rlm_submission, "session:test", run_id}

    assert snapshot.selected_run_id == run_id
    assert Queries.run_timeline(store, run_id) != []

    assert Enum.any?(
             snapshot.messages,
             &(&1.role == "assistant" and &1.message_kind == "workflow_output" and
                 &1.content == "Three selected repos: runic_ai, compendium, libbit.")
           )

    assert Enum.any?(
             snapshot.messages,
             &(&1.role == "user" and &1.message_kind == "objective" and
                 &1.content == "Pick three repos")
           )
  end

  test "conversation view budgets wrapped rows and tails the selected long response", %{
    store: store
  } do
    long_response =
      String.duplicate(
        "This assistant response should remain readable in the chat transcript instead of being capped at a short fixed card height. ",
        40
      )

    model = %{
      model(store)
      | messages: [
          %{
            id: "msg:user",
            role: "user",
            message_kind: "objective",
            content: "Explain workflow graphs."
          },
          %{
            id: "msg:assistant",
            role: "assistant",
            message_kind: "direct_response",
            content: long_response
          }
        ],
        selected_message_id: "msg:assistant"
    }

    widget = Conversation.widget(model, 10, 60)
    [{_user_widget, user_height}, {assistant_widget, assistant_height}] = widget.items

    assert widget.selected == 1
    assert assistant_widget.content =~ "Assistant / direct_response"
    assert assistant_height > 12
    assert widget.scroll_offset == user_height + assistant_height - 10
  end

  test "conversation view supports row scrollback and exposes scrollbar state", %{
    store: store
  } do
    long_response =
      String.duplicate(
        "This assistant response should be scrollable inside the chat transcript. ",
        40
      )

    tail_model =
      %{
        model(store)
        | messages: [
            %{
              id: "msg:user",
              role: "user",
              message_kind: "objective",
              content: "Explain workflow graphs."
            },
            %{
              id: "msg:assistant",
              role: "assistant",
              message_kind: "direct_response",
              content: long_response
            }
          ],
          selected_message_id: "msg:assistant"
      }

    tail_widget = Conversation.widget(tail_model, 10, 60)
    assert tail_widget.scroll_offset > 0
    assert tail_widget.block.title =~ "tail"

    scrolled_widget =
      tail_model
      |> Map.put(:conversation_scrollback_rows, 5)
      |> Conversation.widget(10, 60)

    assert scrolled_widget.scroll_offset == max(tail_widget.scroll_offset - 5, 0)
    assert scrolled_widget.block.title =~ "5 rows back"

    assert scrollbar = Conversation.scrollbar(scrolled_widget, tail_model, 10)
    assert scrollbar.position == scrolled_widget.scroll_offset
    assert scrollbar.viewport_content_length == 10
    assert scrollbar.content_length > 10
  end

  test "conversation view renders markdown and mermaid blocks through content boundary", %{
    store: store
  } do
    markdown_model = %{
      model(store)
      | messages: [
          %{
            id: "msg:assistant:markdown",
            role: "assistant",
            message_kind: "direct_response",
            content: "## Result\n\n```elixir\nIO.puts(:ok)\n```"
          }
        ]
    }

    markdown_widget = Conversation.widget(markdown_model, 20, 80)
    [{assistant_widget, _height}] = markdown_widget.items
    assert %ExRatatui.Widgets.Markdown{} = assistant_widget
    assert assistant_widget.content =~ "```elixir"

    mermaid_model = %{
      markdown_model
      | graph: :mermaid,
        messages: [
          %{
            id: "msg:assistant:mermaid",
            role: "assistant",
            message_kind: "direct_response",
            content: "```mermaid\nflowchart TD\n  A --> B\n```"
          }
        ]
    }

    mermaid_widget = Conversation.widget(mermaid_model, 20, 80)
    [{assistant_widget, _height}] = mermaid_widget.items
    assert %ExRatatui.Widgets.Paragraph{} = assistant_widget
    assert inspect(assistant_widget.text) =~ "flowchart TD"
  end

  test "conversation view uses cached inline graph output for row height and tail scroll", %{
    store: store
  } do
    source = "flowchart TD\n  A --> B"

    cached_output =
      1..40
      |> Enum.map_join("\n", &"rendered graph line #{&1}")

    base_model = %{
      model(store)
      | graph: :mmdflux,
        messages: [
          %{
            id: "msg:assistant:mermaid-cache",
            role: "assistant",
            message_kind: "direct_response",
            content: "Before graph\n\n```mermaid\n#{source}\n```\n\nAfter graph"
          }
        ]
    }

    [graph_source] = RenderCache.graph_sources(base_model)

    assert graph_source.key ==
             RenderCache.mermaid_source_key(
               "msg:assistant:mermaid-cache:block:2",
               source
             )

    cache =
      RenderCache.put(
        %{},
        RenderCache.graph_key(graph_source, mode: base_model.graph, theme: base_model.theme),
        %{
          key: nil,
          status: :ok,
          output: cached_output,
          warning: nil,
          mode: :mmdflux,
          rendered_at: DateTime.utc_now()
        }
      )

    model = %{base_model | render_cache: cache}

    assert %{output: ^cached_output} =
             RenderCache.fetch_graph(cache, graph_source,
               mode: model.graph,
               theme: model.theme
             )

    inline_source = %{
      key: RenderCache.mermaid_source_key("msg:assistant:mermaid-cache:block:2", source),
      title: "Mermaid",
      kind: :mermaid,
      source: source
    }

    assert %{output: ^cached_output} =
             RenderCache.fetch_graph(model.render_cache, inline_source,
               mode: model.graph,
               theme: model.theme
             )

    assert RunicAI.Terminal.ExRatatui.Views.Content.graph_block_text(
             source,
             model,
             "msg:assistant:mermaid-cache:block:2"
           ) == cached_output

    widget = Conversation.widget(model, 10, 72)
    [{assistant_widget, height}] = widget.items
    rendered_text = widget_text(assistant_widget)

    assert %ExRatatui.Widgets.Paragraph{} = assistant_widget
    assert rendered_text =~ "rendered graph line 40"
    refute rendered_text =~ "Rendering Mermaid diagram"
    assert height >= 44
    assert widget.scroll_offset == height - 10
  end

  test "markdown blocks, syntax, and stream buffers expose stable primitives" do
    markdown = """
    # Heading

    ```mermaid
    flowchart TD
      A --> B
    ```

    ```diff
    +added
    -removed
    ```
    """

    blocks = MarkdownBlocks.parse(markdown, source_id: "msg:test")
    assert Enum.any?(blocks, &(&1.kind == :mermaid))
    assert Enum.any?(blocks, &(&1.kind == :diff))

    diff_roles =
      "+added\n-removed"
      |> Syntax.tokenize("diff")
      |> List.flatten()
      |> Enum.map(& &1.role)

    assert :diff_added in diff_roles
    assert :diff_removed in diff_roles

    {buffers, message} =
      StreamBuffer.append(StreamBuffer.new(), %{
        stream_id: "s1",
        run_id: "run:test",
        chunk: "hello"
      })

    assert message.content == "hello"
    assert message.stream_complete == false

    {_buffers, message} = StreamBuffer.finalize(buffers, %{stream_id: "s1", chunk: " world"})
    assert message.content == "hello world"
    assert message.stream_complete == true

    {_buffers, message} = StreamBuffer.fail(buffers, %{stream_id: "s1", reason: "network lost"})
    assert message.content =~ "[stream failed: network lost]"
    assert message.stream_complete == true
    assert message.content_json.status == "error"
  end

  test "raw HTML is escaped outside fenced code while code stays intact", %{store: store} do
    markdown = """
    <section>do not render</section>

    ```html
    <section>keep in code</section>
    ```
    """

    escaped = MarkdownBlocks.escape_raw_html(markdown)
    assert escaped =~ "&lt;section&gt;do not render&lt;/section&gt;"
    assert escaped =~ "<section>keep in code</section>"

    model =
      model(store)
      |> Map.put(:messages, [
        %{
          id: "msg:html",
          role: "assistant",
          message_kind: "direct_response",
          content: markdown
        }
      ])

    [{%ExRatatui.Widgets.Markdown{} = widget, _height}] = Conversation.widget(model, 20, 80).items
    assert widget.content =~ "&lt;section&gt;do not render&lt;/section&gt;"
    assert widget.content =~ "<section>keep in code</section>"
  end

  test "graph render cache renders persisted graph sources without view side effects", %{
    store: store
  } do
    model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))
    sources = Model.graph_sources(model)

    assert sources != []

    cache = RenderCache.render_graph_sources(%{}, sources, mode: :mermaid, theme: :runic)
    first = List.first(sources)

    assert %{output: output} =
             RenderCache.fetch_graph(cache, first, mode: :mermaid, theme: :runic)

    assert output =~ "flowchart"
  end

  test "slash graph mmdflux queues async render work instead of rendering in the view", %{
    store: store
  } do
    model =
      store
      |> model()
      |> then(&Model.apply_snapshot(&1, elem(Commands.load_snapshot(&1), 1)))
      |> Map.put(:slash_mode?, true)
      |> Map.put(:slash_text, "/graph mmdflux")

    assert {:noreply, updated, commands: [%ExRatatui.Command{kind: :async}]} =
             Update.update({:event, %Key{code: "enter", kind: "press"}}, model)

    assert updated.graph == :mmdflux
    assert updated.view_mode == :debug
  end

  test "render cache keys markdown by content hash and width and caches parsed blocks", %{
    store: store
  } do
    model = %{
      model(store)
      | messages: [
          %{
            id: "msg:markdown-cache",
            role: "assistant",
            message_kind: "direct_response",
            content: "## Cached\n\n```elixir\n:ok\n```"
          }
        ]
    }

    [source] = RenderCache.markdown_sources(model)
    width_80_key = RenderCache.markdown_key(source, width: 80, theme: :runic)
    width_100_key = RenderCache.markdown_key(source, width: 100, theme: :runic)

    refute width_80_key == width_100_key

    cache = RenderCache.render_markdown_sources(%{}, [source], width: 80, theme: :runic)

    assert %{blocks: blocks, output: output} =
             RenderCache.fetch_markdown(cache, source, width: 80, theme: :runic)

    assert output =~ "Cached"
    assert Enum.any?(blocks, &(&1.kind == :code))
    assert RenderCache.fetch_markdown(cache, source, width: 100, theme: :runic) == nil
  end

  test "mmdflux graph cache falls back to source when executable is missing" do
    old_path = System.get_env("PATH")
    empty_path = tmp_dir()
    System.put_env("PATH", empty_path)

    on_exit(fn ->
      case old_path do
        nil -> System.delete_env("PATH")
        path -> System.put_env("PATH", path)
      end
    end)

    source = %{
      key: "inline:missing-mmdflux",
      title: "Missing MMDFlux",
      kind: :mermaid,
      source: "flowchart TD\n  A --> B"
    }

    cache = RenderCache.render_graph_sources(%{}, [source], mode: :mmdflux, theme: :runic)

    assert %{status: :blocked, warning: warning, output: output} =
             RenderCache.fetch_graph(cache, source, mode: :mmdflux, theme: :runic)

    assert warning =~ "mmdflux executable was not found"
    assert output =~ "flowchart TD"
  end

  test "headless composer submit keeps the app responsive during a live run", %{store: store} do
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      send(caller, {:submitted, opts[:run_id], objective})

      opts[:event_sink].(%{
        run_id: opts[:run_id],
        stage: :node_started,
        status: :running,
        data: %{
          runnable: %{id: "runnable:headless", node: "plan", component_id: "plan"},
          input: %{objective: objective}
        }
      })

      {:ok, assistant_result()}
    end

    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        run_fun: run_fun,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    :ok = Runtime.inject_event(pid, %Key{code: "h", kind: "press"})
    :ok = Runtime.inject_event(pid, %Key{code: "i", kind: "press"})
    :ok = Runtime.inject_event(pid, %Key{code: "enter", kind: "press"})

    assert_receive {:submitted, run_id, "hi"}, 1_000
    assert eventually(fn -> Queries.run_timeline(store, run_id) != [] end)
    assert eventually(fn -> :sys.get_state(pid).user_state.active_run? == false end)
    assert Enum.any?(Queries.messages_for_run(store, run_id), &(&1.role == "user"))

    :ok = Runtime.inject_event(pid, %Key{code: "tab", kind: "press"})
    assert eventually(fn -> :sys.get_state(pid).user_state.focus == :composer end)

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "composer captures printable shortcut letters instead of firing global commands", %{
    store: store
  } do
    caller = self()

    run_fun = fn _cwd, objective, opts ->
      send(caller, {:submitted, opts[:run_id], objective})
      {:ok, assistant_result()}
    end

    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        run_fun: run_fun,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    inject_text(pid, "query review errors")
    :ok = Runtime.inject_event(pid, %Key{code: "enter", kind: "press"})

    assert_receive {:submitted, _run_id, "query review errors"}, 1_000
    assert eventually(fn -> Process.alive?(pid) end)

    state = :sys.get_state(pid).user_state
    assert state.status_message != "managed workflows loaded"
    assert state.last_export_path == nil

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "typed slash commands keep printable command letters and clear native input", %{
    store: store
  } do
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    inject_text(pid, "/help")
    :ok = Runtime.inject_event(pid, %Key{code: "enter", kind: "press"})

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state
             state.status_message == "slash commands" and state.search_results != []
           end)

    state = :sys.get_state(pid).user_state
    assert state.slash_mode? == false
    assert ExRatatui.textarea_get_value(state.slash_ref) == ""

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "slash suggestions complete commands and contextual arguments", %{store: store} do
    model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))

    suggestions = CommandSuggestions.suggest(model, "/he")
    assert [%{replacement: "/help "} | _] = suggestions

    graph_suggestions = CommandSuggestions.suggest(model, "/graph m")
    assert [%{replacement: "/graph mermaid"} | _] = graph_suggestions

    log_suggestions = CommandSuggestions.suggest(model, "/logs e")
    assert [%{replacement: "/logs error"} | _] = log_suggestions

    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    inject_text(pid, "/he")

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state
             state.slash_mode? and state.suggestions != []
           end)

    :ok = Runtime.inject_event(pid, %Key{code: "tab", kind: "press"})

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state
             state.slash_text == "/help "
           end)

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "streaming info updates the conversation pane without blocking composer", %{store: store} do
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)

    send(
      pid,
      {:runic_ai_tui_stream, %{stream_id: "assistant:test", run_id: "run:test", chunk: "hello"}}
    )

    send(
      pid,
      {:runic_ai_tui_stream, %{stream_id: "assistant:test", run_id: "run:test", chunk: " world"}}
    )

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state

             Enum.any?(
               state.messages,
               &(&1.id == "stream:assistant:test" and &1.content == "hello world" and
                   &1.stream_complete == false)
             )
           end)

    inject_text(pid, " still typing")
    assert eventually(fn -> :sys.get_state(pid).user_state.composer_text == " still typing" end)

    send(
      pid,
      {:runic_ai_tui_stream_complete,
       %{stream_id: "assistant:test", run_id: "run:test", chunk: ""}}
    )

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state

             Enum.any?(
               state.messages,
               &(&1.content == "hello world" and &1.stream_complete == true and
                   &1.message_kind == "stream")
             )
           end)

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "stream updates do not auto-follow when the user scrolled away", %{store: store} do
    model = %{
      model(store)
      | messages: [
          %{
            id: "msg:anchor",
            role: "assistant",
            message_kind: "direct_response",
            content: "Earlier answer"
          }
        ],
        selected_message_id: "msg:anchor",
        conversation_scrollback_rows: 12
    }

    model =
      Model.append_stream(model, %{
        stream_id: "assistant:scrolled",
        run_id: "run:test",
        chunk: "new streamed text"
      })

    assert model.selected_message_id == "msg:anchor"
    assert model.conversation_scrollback_rows == 12
    assert Enum.any?(model.messages, &(&1.id == "stream:assistant:scrolled"))
  end

  test "stream completion and failure persistence reload from SQLite", %{store: store} do
    model =
      store
      |> model()
      |> then(&Model.apply_snapshot(&1, elem(Commands.load_snapshot(&1), 1)))

    assert {:ok, %{reload_snapshot: snapshot}} =
             Commands.record_stream_update(
               model,
               %{
                 stream_id: "assistant:complete",
                 run_id: "run:stream-complete",
                 content: "complete answer"
               },
               true
             )

    assert Enum.any?(
             snapshot.messages,
             &(&1.content == "complete answer" and &1.message_kind == "stream" and
                 &1.stream_complete)
           )

    assert {:ok, %{reload_snapshot: failed_snapshot}} =
             Commands.record_stream_update(
               model,
               %{
                 stream_id: "assistant:failed",
                 run_id: "run:stream-failed",
                 content: "partial answer\n[stream failed: network lost]",
                 status: "failed",
                 reason: "network lost"
               },
               true
             )

    assert Enum.any?(
             failed_snapshot.messages,
             &(&1.message_kind == "stream_error" and &1.content =~ "stream failed")
           )
  end

  test "thread polish commands start, switch, rename, edit, and retry", %{store: store} do
    model =
      model(store)
      |> then(&Model.apply_snapshot(&1, elem(Commands.load_snapshot(&1), 1)))

    assert {:ok, {:new}} = SlashCommands.parse("/new")
    assert {:ok, {:switch, "run:test"}} = SlashCommands.parse("/switch run:test")
    assert {:ok, {:rename, "Readable title"}} = SlashCommands.parse("/rename Readable title")
    assert {:ok, {:retry}} = SlashCommands.parse("/retry")
    assert {:ok, {:edit}} = SlashCommands.parse("/edit")

    assert {:ok, renamed} = Commands.rename_run(model, "Readable title")
    assert [%{id: "run:test", workflow_name: "Readable title"}] = renamed.runs

    new_thread = Model.new_thread(model, "assistant:tui:test")
    assert new_thread.selected_run_id == "assistant:tui:test"
    assert new_thread.messages == []
  end

  test "log filters narrow captured logs in model and log view", %{store: store} do
    logs = [
      %{at: "10:00:00", level: "info", source: "agent.runner", message: "started"},
      %{at: "10:00:01", level: "error", source: "agent.runner", message: "failed"},
      %{at: "10:00:02", level: "warning", source: "sqlite", message: "busy"}
    ]

    model = %{model(store) | logs: logs}

    error_model = Model.put_log_filter(model, "error")
    assert [%{message: "failed"}] = Model.filtered_logs(error_model)

    assert %ExRatatui.Widgets.Paragraph{} = widget = Logs.widget(error_model, 8)
    assert widget.block.title == "Logs 1/3 | error"
    assert widget.text =~ "failed"
    refute widget.text =~ "started"

    source_model = Model.put_log_filter(model, "source:sqlite")
    assert [%{message: "busy"}] = Model.filtered_logs(source_model)
    assert Logs.widget(source_model, 8).block.title == "Logs 1/3 | sqlite"
  end

  test "prompt inspector and review modal redact secrets while rendering Markdown", %{
    store: store
  } do
    model =
      store
      |> model()
      |> then(&Model.apply_snapshot(&1, elem(Commands.load_snapshot(&1), 1)))
      |> Map.put(:selected_event_id, "event:start")
      |> Map.put(:detail_mode, :prompt_context)

    assert %ExRatatui.Widgets.Markdown{} = details = Details.widget(model)
    assert details.content =~ "## Run"
    assert details.content =~ "[REDACTED]"
    refute details.content =~ "sk-testsecret"

    review_model = %{
      model
      | selected_review_id: "review:redacted",
        review_requests: [
          %{
            id: "review:redacted",
            kind: "command",
            status: "pending",
            checkpoint: "checkpoint:redacted",
            resume_key: "resume:redacted",
            details: %{command: "curl", api_key: "sk-testsecret123456"}
          }
        ]
    }

    assert %ExRatatui.Widgets.Popup{content: %ExRatatui.Widgets.Markdown{} = review} =
             ReviewModal.widget(review_model)

    assert review.content =~ "[REDACTED]"
    refute review.content =~ "sk-testsecret"
  end

  test "captures Logger output in TUI state instead of leaving console active", %{store: store} do
    before_level = default_logger_level()
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    marker = "ratatui log capture #{System.unique_integer([:positive])}"
    Logger.warning(marker)

    assert eventually(fn ->
             pid
             |> :sys.get_state()
             |> Map.fetch!(:user_state)
             |> Map.fetch!(:logs)
             |> Enum.any?(&(to_string(&1.message) =~ marker))
           end)

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    assert default_logger_level() == before_level
  end

  test "empty slash searches stay visible as zero-result searches", %{store: store} do
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, pid} =
      App.start_link(
        options: options,
        store: store,
        test_mode: {100, 30},
        name: nil
      )

    Process.sleep(100)
    inject_text(pid, "/search does-not-exist")
    :ok = Runtime.inject_event(pid, %Key{code: "enter", kind: "press"})

    assert eventually(fn ->
             state = :sys.get_state(pid).user_state
             state.search_term == "does-not-exist" and state.search_results == []
           end)

    state = :sys.get_state(pid).user_state
    assert Timeline.widget(state).block.title == "Search does-not-exist 0"

    :ok = Runtime.inject_event(pid, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
  end

  test "multiple TUI sessions share SQLite while keeping isolated UI state", %{store: store} do
    {:ok, options} = Options.parse(["--cwd", tmp_dir(), "--persistence", "memory"])

    {:ok, first} = App.start_link(options: options, store: store, test_mode: {100, 30}, name: nil)

    {:ok, second} =
      App.start_link(options: options, store: store, test_mode: {100, 30}, name: nil)

    Process.sleep(100)
    assert :sys.get_state(first).user_state.runs != []
    assert :sys.get_state(second).user_state.runs != []

    :ok = Runtime.inject_event(first, %Key{code: "tab", kind: "press"})
    assert eventually(fn -> :sys.get_state(first).user_state.focus == :composer end)
    assert :sys.get_state(second).user_state.focus == :conversation

    :ok = Runtime.inject_event(first, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
    :ok = Runtime.inject_event(second, %Key{code: "q", kind: "press", modifiers: ["ctrl"]})
  end

  test "managed workflow start and resume delegate to caller-owned runner APIs", %{store: store} do
    model = Model.apply_snapshot(model(store), elem(Commands.load_snapshot(model(store)), 1))
    caller = self()

    managed_start_fun = fn _model, workflow, run ->
      send(caller, {:started, workflow.workflow_key, run.id})
      :ok
    end

    resume_fun = fn _model, workflow ->
      send(caller, {:resumed, workflow.workflow_key})
      :ok
    end

    model = %{model | managed_start_fun: managed_start_fun, resume_fun: resume_fun}

    assert {:ok, started} = Commands.start_managed_workflow(model, "nightly-agent")
    assert_receive {:started, "nightly-agent", "run:" <> _}

    assert [%{workflow_key: "nightly-agent", last_run_id: "run:" <> _}] =
             started.managed_workflows

    assert {:ok, resumed} =
             Commands.resume_workflow(
               %{model | managed_workflows: started.managed_workflows},
               nil
             )

    assert_receive {:resumed, "nightly-agent"}
    assert resumed.status_message =~ "delegated to live runner"
  end

  test "hydrates from an on-disk SQLite database after reopening" do
    dir = tmp_dir()
    sqlite_path = Path.join(dir, ".runic_ai/runs.db")

    {:ok, first} = SQLite.open(database: sqlite_path, migrate?: true)
    seed_store(first)
    SQLite.close(first)

    {:ok, second} = SQLite.open(database: sqlite_path, migrate?: true)
    on_exit(fn -> SQLite.close(second) end)

    assert {:ok, snapshot} = Commands.load_snapshot(model(second))
    assert [%{id: "run:test"}] = snapshot.runs
    assert [%{workflow_key: "nightly-agent"}] = snapshot.managed_workflows
  end

  defp model(store) do
    {:ok, options} =
      Options.parse(["--cwd", tmp_dir(), "--persistence", "memory", "--run", "run:test"])

    options
    |> Model.new(store: store)
    |> Model.put_store(store, false)
  end

  defp seed_store(store) do
    now = DateTime.utc_now()

    record!(store, %{
      id: "event:start",
      at: now,
      session_id: "session:test",
      agent: :assistant,
      kind: :status,
      phase: :start,
      status: :running,
      title: "Assistant started",
      detail: "objective",
      data: %{
        run_id: "run:test",
        objective: "debug durable tui",
        model: "test:model",
        prompt: "Use API_KEY=sk-testsecret123456 while drafting context."
      }
    })

    record!(store, %{
      id: "event:runnable",
      at: DateTime.add(now, 1, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :rlm_node,
      phase: :node_started,
      status: :running,
      title: "Node started",
      detail: "plan",
      data: %{
        run_id: "run:test",
        data: %{
          runnable: %{
            id: "runnable:1",
            node: "plan",
            component_id: "plan",
            component_type: "blueprint_proposer"
          },
          input: %{objective: "debug durable tui"}
        }
      }
    })

    record!(store, %{
      id: "event:tool",
      at: DateTime.add(now, 2, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :tool,
      phase: :complete,
      status: :ok,
      title: "Tool completed",
      detail: "grep",
      data: %{run_id: "run:test", tool_name: "grep", args: %{q: "dangerous"}, result: %{ok: true}}
    })

    record!(store, %{
      id: "event:review",
      at: DateTime.add(now, 3, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :hitl,
      phase: :review,
      status: :review,
      title: "Review dangerous command",
      detail: "dangerous shell command",
      data: %{
        id: "review:test",
        run_id: "run:test",
        kind: "command",
        checkpoint: "checkpoint:test",
        resume_key: "resume:test",
        details: %{reason: "dangerous command", command: "rm -rf nope"}
      }
    })

    record!(store, %{
      id: "event:repair",
      at: DateTime.add(now, 4, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :repair,
      phase: :repair,
      status: :ok,
      title: "Repair attempted",
      detail: "bounded repair",
      data: %{run_id: "run:test", reason: %{why: "missing path"}, status: "ok"}
    })

    record!(store, %{
      id: "event:summary",
      at: DateTime.add(now, 5, :second),
      session_id: "session:test",
      agent: :assistant,
      kind: :summary,
      phase: :scorecard,
      status: :ok,
      title: "Scorecard",
      detail: "objective satisfied",
      data: %{
        run_id: "run:test",
        scorecard: %{
          objective_status: "objective_satisfied",
          artifact_path: ".docs/result.md",
          residual_risks: [],
          changed_files: [".docs/result.md"]
        },
        artifacts: [%{kind: "report", path: ".docs/result.md", payload: %{ok: true}}],
        graph_summary: %{
          nodes: [%{id: "plan"}, %{id: "write"}],
          edges: [%{from: "plan", to: "write"}]
        }
      }
    })

    {:ok, _workflow} =
      ManagedWorkflows.create(store, %{
        id: "managed:test",
        workflow_key: "nightly-agent",
        workflow_name: "Nightly Agent",
        status: :paused,
        checkpoint_strategy: :on_complete,
        restart_policy: :manual,
        metadata_json: %{trigger: "cron"}
      })

    :ok
  end

  defp record!(store, attrs) do
    attrs = Map.put_new(attrs, :run_id, get_in(attrs, [:data, :run_id]))
    assert {:ok, _event} = SQLite.record_terminal_event(store, attrs)
  end

  defp assistant_result do
    scorecard = %{
      objective_status: :objective_satisfied,
      artifact_path: ".docs/tui.md",
      residual_risks: []
    }

    %{
      agent: :assistant,
      status: :ok,
      scorecard: scorecard,
      objective_scorecard: scorecard,
      artifacts: [%{path: ".docs/tui.md"}],
      episodes: []
    }
  end

  defp rlm_result(output) do
    %{
      context: %{
        episodes: [
          Episode.new!(:satisfied, output,
            id: "episode:answer",
            parent_node_id: "answer",
            artifacts: [output]
          )
        ]
      },
      objective_scorecard: %{objective_status: :objective_satisfied}
    }
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) when is_function(fun, 0) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp default_logger_level do
    case :logger.get_handler_config(:default) do
      {:ok, %{level: level}} -> level
      _other -> nil
    end
  end

  defp inject_text(pid, text) do
    text
    |> String.graphemes()
    |> Enum.each(fn grapheme ->
      :ok = Runtime.inject_event(pid, %Key{code: grapheme, kind: "press"})
    end)
  end

  defp widget_text(%ExRatatui.Widgets.Markdown{content: content}), do: content
  defp widget_text(%ExRatatui.Widgets.Paragraph{text: text}), do: text_to_string(text)

  defp text_to_string(text) when is_binary(text), do: text

  defp text_to_string(%ExRatatui.Text{lines: lines}) do
    Enum.map_join(lines, "\n", &line_to_string/1)
  end

  defp text_to_string(%ExRatatui.Text.Line{} = line), do: line_to_string(line)

  defp text_to_string(lines) when is_list(lines) do
    Enum.map_join(lines, "\n", &text_to_string/1)
  end

  defp text_to_string(other), do: inspect(other)

  defp line_to_string(%ExRatatui.Text.Line{spans: spans}) do
    Enum.map_join(spans, "", fn
      %ExRatatui.Text.Span{content: content} -> content
      other -> inspect(other)
    end)
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-tui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
