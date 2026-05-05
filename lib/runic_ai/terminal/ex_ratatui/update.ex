defmodule RunicAI.Terminal.ExRatatui.Update do
  @moduledoc """
  Reducer update logic for the ExRatatui workbench.
  """

  alias ExRatatui.Command
  alias ExRatatui.Event.Key
  alias RunicAI.Terminal.ExRatatui.Commands
  alias RunicAI.Terminal.ExRatatui.Keymap
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.RenderCache
  alias RunicAI.Terminal.ExRatatui.SlashCommands

  @composer_submit_delay_ms 120

  @spec init_commands(Model.t()) :: [Command.t()]
  def init_commands(%Model{} = model), do: [hydrate_command(model)]

  @spec update(term(), Model.t()) :: {:noreply, Model.t(), keyword()} | {:stop, Model.t()}
  def update({:event, event}, %Model{} = model) do
    event
    |> Keymap.event_to_action(key_context(model))
    |> handle_action(model)
  end

  def update({:info, :refresh}, %Model{} = model) do
    {:noreply, %{model | status_message: "refreshing"}, commands: [hydrate_command(model)]}
  end

  def update({:info, {:hydrated, {:ok, snapshot}}}, %Model{} = model) do
    model = Model.apply_snapshot(model, snapshot)
    {:noreply, model, commands: render_commands(model)}
  end

  def update({:info, {:hydrated, {:error, reason}}}, %Model{} = model) do
    {:noreply, Model.put_error(model, reason)}
  end

  def update({:info, {:searched, {:ok, result}}}, %Model{} = model) do
    {:noreply, apply_result(model, result)}
  end

  def update({:info, {:searched, {:error, reason}}}, %Model{} = model) do
    {:noreply, Model.put_error(model, reason)}
  end

  def update({:info, {:command_result, {:ok, result}}}, %Model{} = model) do
    model = apply_result(model, result)
    {:noreply, model, commands: render_commands(model)}
  end

  def update({:info, {:command_result, {:error, reason}}}, %Model{} = model) do
    {:noreply, Model.put_error(model, reason)}
  end

  def update({:info, {:graph_rendered, {:ok, result}}}, %Model{} = model) do
    {:noreply, apply_result(model, result)}
  end

  def update({:info, {:graph_rendered, {:error, reason}}}, %Model{} = model) do
    {:noreply, Model.put_error(model, reason)}
  end

  def update({:info, {:stream_persisted, {:ok, %{reload_snapshot: snapshot}}}}, %Model{} = model) do
    model = Model.apply_snapshot(model, snapshot)
    {:noreply, model, commands: render_commands(model)}
  end

  def update({:info, {:stream_persisted, {:ok, _result}}}, %Model{} = model) do
    {:noreply, model}
  end

  def update({:info, {:stream_persisted, {:error, reason}}}, %Model{} = model) do
    {:noreply, Model.put_error(model, reason)}
  end

  def update({:info, {:runic_ai_tui_stream, attrs}}, %Model{} = model) do
    model = Model.append_stream(model, attrs)

    {:noreply, model,
     commands:
       [
         Command.async(
           fn -> Commands.record_stream_update(model, attrs, false) end,
           &{:stream_persisted, &1}
         )
       ] ++ render_commands(model)}
  end

  def update({:info, {:runic_ai_tui_stream_complete, attrs}}, %Model{} = model) do
    model = Model.finalize_stream(model, attrs)

    attrs =
      Map.put(attrs, :content, (Model.selected_message(model) || %{}) |> Map.get(:content, ""))

    {:noreply, model,
     commands:
       [
         Command.async(
           fn -> Commands.record_stream_update(model, attrs, true) end,
           &{:stream_persisted, &1}
         )
       ] ++ render_commands(model)}
  end

  def update({:info, {:runic_ai_tui_stream_failed, attrs}}, %Model{} = model) do
    model = Model.fail_stream(model, attrs)

    attrs =
      attrs
      |> Map.put(:content, (Model.selected_message(model) || %{}) |> Map.get(:content, ""))
      |> Map.put(:status, "failed")

    {:noreply, model,
     commands:
       [
         Command.async(
           fn -> Commands.record_stream_update(model, attrs, true) end,
           &{:stream_persisted, &1}
         )
       ] ++ render_commands(model)}
  end

  def update({:info, {:runic_ai_tui_stream_interrupted, attrs}}, %Model{} = model) do
    model = Model.interrupt_stream(model, attrs)

    attrs =
      attrs
      |> Map.put(:content, (Model.selected_message(model) || %{}) |> Map.get(:content, ""))
      |> Map.put(:status, "interrupted")

    {:noreply, model,
     commands:
       [
         Command.async(
           fn -> Commands.record_stream_update(model, attrs, true) end,
           &{:stream_persisted, &1}
         )
       ] ++ render_commands(model)}
  end

  def update({:info, {:runic_ai_tui_log, log}}, %Model{} = model) do
    {:noreply, Model.append_log(model, log)}
  end

  def update({:info, {:run_completed, {:ok, snapshot}}}, %Model{} = model) do
    model = %{Model.apply_snapshot(model, snapshot) | active_run?: false}
    {:noreply, model, commands: render_commands(model)}
  end

  def update({:info, {:run_completed, {:error, reason}}}, %Model{} = model) do
    {:noreply, %{Model.put_error(model, reason) | active_run?: false}}
  end

  def update({:info, {:deferred_composer_submit, submit_id}}, %Model{} = model) do
    handle_deferred_composer_submit(model, submit_id)
  end

  def update(_msg, %Model{} = model), do: {:noreply, model}

  defp handle_action(:quit, %Model{} = model), do: {:stop, model}
  defp handle_action(:ignore, %Model{} = model), do: {:noreply, model}
  defp handle_action(:stop, %Model{} = model), do: {:noreply, %{model | active_run?: false}}

  defp handle_action({:focus, direction}, %Model{} = model),
    do: {:noreply, Model.cycle_focus(model, direction)}

  defp handle_action({:move, delta}, %Model{} = model), do: move(model, delta)

  defp handle_action({:scroll_conversation, action}, %Model{} = model) do
    {:noreply, Model.scroll_conversation(model, action)}
  end

  defp handle_action({:composer_history, direction}, %Model{} = model) do
    {model, text} = Model.navigate_composer_history(model, direction, composer_value(model))

    case text do
      nil ->
        {:noreply, model}

      text ->
        set_textarea(model.composer_ref, text, cursor: :end)
        {:noreply, model}
    end
  end

  defp handle_action({:complete_suggestion, direction}, %Model{} = model) do
    model = Model.move_suggestion(model, direction)

    case Model.selected_suggestion(model) do
      nil ->
        {:noreply, model}

      suggestion ->
        set_textarea(model.slash_ref, suggestion.replacement, cursor: :end)
        {:noreply, Model.set_slash_text(model, suggestion.replacement)}
    end
  end

  defp handle_action(:slash_mode, %Model{} = model) do
    set_textarea(model.slash_ref, "/", cursor: :end)
    {:noreply, Model.set_slash_text(model, "/")}
  end

  defp handle_action(:toggle_detail, %Model{} = model) do
    {:noreply, %{model | detail_visible?: not model.detail_visible?}}
  end

  defp handle_action(:toggle_view, %Model{} = model) do
    model = Model.toggle_view_mode(model)
    {:noreply, %{model | status_message: "view: #{model.view_mode}"}}
  end

  defp handle_action(:cycle_graph, %Model{} = model) do
    graph =
      case model.graph do
        :text -> :mermaid
        :mermaid -> :mmdflux
        :mmdflux -> :text
      end

    model = %{model | graph: graph, status_message: "graph: #{graph}"}
    {:noreply, model, commands: render_commands(model)}
  end

  defp handle_action(:cancel, %Model{} = model) do
    set_textarea(model.slash_ref, "")

    model = Model.clear_suggestions(model)

    {:noreply,
     %{
       model
       | slash_mode?: false,
         slash_text: "",
         pending_composer_submit_id: nil,
         status_message: "ready"
     }}
  end

  defp handle_action(:submit, %Model{slash_mode?: true} = model) do
    submit_slash(model, model.slash_text)
  end

  defp handle_action(:submit, %Model{} = model) do
    defer_composer_submit(model)
  end

  defp handle_action({:slash_command, command}, %Model{} = model),
    do: submit_slash(model, command)

  defp handle_action({:text_key, %Key{} = key}, %Model{slash_mode?: true} = model) do
    forward_text_key(model.slash_ref, key)
    {:noreply, Model.set_slash_text(model, input_value(model.slash_ref))}
  end

  defp handle_action({:text_key, %Key{} = key}, %Model{} = model) do
    model = flush_pending_composer_submit(model)

    forward_text_key(model.composer_ref, key)

    model =
      model
      |> Model.set_composer_text(input_value(model.composer_ref))
      |> Model.reset_composer_history_navigation()

    {:noreply, model}
  end

  defp submit_composer_now(%Model{} = model, text) do
    if String.trim(text) == "" do
      {:noreply, %{model | pending_composer_submit_id: nil}}
    else
      model = %{
        (Model.set_composer_text(model, text)
         |> Model.remember_composer_submission(text))
        | active_run?: true,
          status_message: "running"
      }

      clear_textareas(model)

      {:noreply, Model.clear_composer(model),
       commands: [
         Command.async(fn -> Commands.start_agent_run(model, text) end, &{:run_completed, &1})
       ]}
    end
  end

  defp handle_deferred_composer_submit(
         %Model{pending_composer_submit_id: submit_id} = model,
         submit_id
       )
       when not is_nil(submit_id) do
    submit_composer_now(%{model | pending_composer_submit_id: nil}, composer_value(model))
  end

  defp handle_deferred_composer_submit(%Model{} = model, _submit_id), do: {:noreply, model}

  defp defer_composer_submit(%Model{} = model) do
    text = composer_value(model)

    if String.trim(text) == "" do
      {:noreply, %{model | pending_composer_submit_id: nil}}
    else
      submit_id = System.unique_integer([:positive])

      {:noreply, %{model | pending_composer_submit_id: submit_id, status_message: "submitting"},
       commands: [
         Command.send_after(@composer_submit_delay_ms, {:deferred_composer_submit, submit_id})
       ]}
    end
  end

  defp flush_pending_composer_submit(%Model{pending_composer_submit_id: nil} = model), do: model

  defp flush_pending_composer_submit(%Model{} = model) do
    text = composer_value(model)
    text = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"

    set_textarea(model.composer_ref, text, cursor: :end)

    %{
      Model.set_composer_text(model, text)
      | pending_composer_submit_id: nil,
        status_message: "composer"
    }
  end

  defp move(%Model{focus: :runs} = model, delta) do
    model = Model.move_selection(model, delta)
    {:noreply, model, commands: [hydrate_command(model)]}
  end

  defp move(%Model{} = model, delta), do: {:noreply, Model.move_selection(model, delta)}

  defp submit_slash(%Model{} = model, command_text) do
    case SlashCommands.parse(command_text) do
      {:ok, {:quit}} ->
        {:stop, model}

      {:ok, {:help}} ->
        set_textarea(model.slash_ref, "")

        {:noreply,
         %{
           Model.clear_suggestions(model)
           | status_message: "slash commands",
             slash_mode?: false,
             slash_text: "",
             search_term: "help",
             search_results: [
               %{
                 id: "help",
                 title: "Slash commands",
                 detail: SlashCommands.help_text(),
                 status: "ok"
               }
             ]
         }}

      {:ok, command} ->
        run_command(model, command)

      {:error, reason} ->
        {:noreply, %{model | status: :error, status_message: reason}}
    end
  end

  defp run_command(%Model{} = model, {:search, term}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: "", search_term: term},
     commands: [Command.async(fn -> Commands.search(model, term) end, &{:searched, &1})]}
  end

  defp run_command(%Model{} = model, {:source, term}), do: run_command(model, {:search, term})

  defp run_command(%Model{} = model, {:find, term}) do
    set_textarea(model.slash_ref, "")

    results =
      Enum.filter(model.messages, fn message ->
        String.contains?(String.downcase(message.content || ""), String.downcase(term))
      end)

    selected = List.first(results)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         conversation_search: term,
         conversation_scrollback_rows: 0,
         selected_message_id: selected && selected.id,
         status_message: "conversation search: #{length(results)}"
     }}
  end

  defp run_command(%Model{} = model, {:new}) do
    set_textarea(model.slash_ref, "")
    model = model |> Model.clear_suggestions() |> Model.new_thread() |> Model.put_view_mode(:chat)
    {:noreply, %{model | slash_mode?: false, slash_text: "", focus: :composer}}
  end

  defp run_command(%Model{} = model, {:switch, run_id}) do
    set_textarea(model.slash_ref, "")

    model = %{
      Model.clear_suggestions(model)
      | selected_run_id: run_id,
        run_id: run_id,
        conversation_scrollback_rows: 0,
        slash_mode?: false,
        slash_text: ""
    }

    {:noreply, model, commands: [hydrate_command(model)]}
  end

  defp run_command(%Model{} = model, {:rename, title}) do
    set_textarea(model.slash_ref, "")

    {:noreply, %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: ""},
     commands: [
       Command.async(fn -> Commands.rename_run(model, title) end, &{:command_result, &1})
     ]}
  end

  defp run_command(%Model{} = model, {:chat}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :chat)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         search_term: nil,
         search_results: [],
         status_message: "view: chat"
     }}
  end

  defp run_command(%Model{} = model, {:debug}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         status_message: "view: debug"
     }}
  end

  defp run_command(%Model{} = model, {:export, path}) do
    set_textarea(model.slash_ref, "")

    {:noreply, %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: ""},
     commands: [Command.async(fn -> Commands.export_run(model, path) end, &{:command_result, &1})]}
  end

  defp run_command(%Model{} = model, {:managed, status}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: "", focus: :managed},
     commands: [
       Command.async(fn -> Commands.managed_workflows(model, status) end, &{:command_result, &1})
     ]}
  end

  defp run_command(%Model{} = model, {:eval, status}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: "", focus: :evals},
     commands: [
       Command.async(fn -> Commands.eval_cohort(model, status) end, &{:command_result, &1})
     ]}
  end

  defp run_command(%Model{} = model, {:start, workflow_key}) do
    set_textarea(model.slash_ref, "")

    {:noreply, %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: ""},
     commands: [
       Command.async(
         fn -> Commands.start_managed_workflow(model, workflow_key) end,
         &{:command_result, &1}
       )
     ]}
  end

  defp run_command(%Model{} = model, {:resume, workflow_key}) do
    set_textarea(model.slash_ref, "")

    {:noreply, %{Model.clear_suggestions(model) | slash_mode?: false, slash_text: ""},
     commands: [
       Command.async(
         fn -> Commands.resume_workflow(model, workflow_key) end,
         &{:command_result, &1}
       )
     ]}
  end

  defp run_command(%Model{} = model, {:graph, nil}) do
    set_textarea(model.slash_ref, "")
    model = %{Model.put_view_mode(model, :debug) | focus: :details}

    handle_action(:cycle_graph, %{
      Model.clear_suggestions(model)
      | slash_mode?: false,
        slash_text: ""
    })
  end

  defp run_command(%Model{} = model, {:graph, mode})
       when mode in ["text", "mermaid", "mmdflux"] do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    graph =
      case mode do
        "text" -> :text
        "mermaid" -> :mermaid
        "mmdflux" -> :mmdflux
      end

    model = %{
      Model.clear_suggestions(model)
      | graph: graph,
        focus: :details,
        slash_mode?: false,
        slash_text: ""
    }

    {:noreply, model, commands: render_commands(model)}
  end

  defp run_command(%Model{} = model, {:reviews}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :details, slash_mode?: false, slash_text: ""}}
  end

  defp run_command(%Model{} = model, {:errors}) do
    set_textarea(model.slash_ref, "")
    errors = Enum.filter(model.timeline, &(&1.status in ["error", "blocked"]))
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | search_term: "errors",
         search_results: errors,
         slash_mode?: false,
         slash_text: ""
     }}
  end

  defp run_command(%Model{} = model, {:tools, _name}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :details, slash_mode?: false, slash_text: ""}}
  end

  defp run_command(%Model{} = model, {:runs, _query}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :runs, slash_mode?: false, slash_text: ""},
     commands: [hydrate_command(model)]}
  end

  defp run_command(%Model{} = model, {:artifacts}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :details, slash_mode?: false, slash_text: ""}}
  end

  defp run_command(%Model{} = model, {:scorecard}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :details, slash_mode?: false, slash_text: ""}}
  end

  defp run_command(%Model{} = model, {:repairs}) do
    set_textarea(model.slash_ref, "")
    model = Model.put_view_mode(model, :debug)

    {:noreply,
     %{Model.clear_suggestions(model) | focus: :details, slash_mode?: false, slash_text: ""}}
  end

  defp run_command(%Model{} = model, {:logs, filter}) do
    set_textarea(model.slash_ref, "")
    model = model |> Model.put_view_mode(:debug) |> Model.put_log_filter(filter)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | focus: :details,
         slash_mode?: false,
         slash_text: ""
     }}
  end

  defp run_command(%Model{} = model, {:prompt}) do
    set_textarea(model.slash_ref, "")
    model = model |> Model.put_view_mode(:debug) |> Model.put_detail_mode(:prompt_context)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | focus: :details,
         slash_mode?: false,
         slash_text: "",
         status_message: "prompt/context inspector"
     }}
  end

  defp run_command(%Model{} = model, {:next, kind}) do
    jump_message(model, kind || "assistant", :next)
  end

  defp run_command(%Model{} = model, {:prev, kind}) do
    jump_message(model, kind || "assistant", :prev)
  end

  defp run_command(%Model{} = model, {:retry}), do: retry_last_turn(model)
  defp run_command(%Model{} = model, {:regenerate}), do: retry_last_turn(model)

  defp run_command(%Model{} = model, {:edit}) do
    set_textarea(model.slash_ref, "")

    case last_user_content(model) do
      nil ->
        {:noreply, %{model | status_message: "no user turn to edit"}}

      objective ->
        set_textarea(model.composer_ref, objective, cursor: :end)

        {:noreply,
         %{
           Model.set_composer_text(model, objective)
           | slash_mode?: false,
             slash_text: "",
             focus: :composer,
             status_message: "editing last user turn"
         }
         |> Model.clear_suggestions()}
    end
  end

  defp run_command(%Model{} = model, {:watch}) do
    set_textarea(model.slash_ref, "")

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         selected_message_id: nil,
         conversation_scrollback_rows: 0,
         status_message: "follow mode"
     }}
  end

  defp run_command(%Model{} = model, {:pause}) do
    set_textarea(model.slash_ref, "")

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         status_message: "follow paused"
     }}
  end

  defp run_command(%Model{} = model, {:stop}) do
    set_textarea(model.slash_ref, "")

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | active_run?: false,
         slash_mode?: false,
         slash_text: "",
         status_message: "stopped"
     }}
  end

  defp retry_last_turn(%Model{} = model) do
    set_textarea(model.slash_ref, "")

    case last_user_content(model) do
      nil ->
        {:noreply, %{model | status_message: "no user turn to retry"}}

      objective ->
        model = %{
          Model.clear_suggestions(model)
          | active_run?: true,
            slash_mode?: false,
            slash_text: "",
            status_message: "retrying"
        }

        {:noreply, model,
         commands: [
           Command.async(
             fn -> Commands.start_agent_run(model, objective) end,
             &{:run_completed, &1}
           )
         ]}
    end
  end

  defp jump_message(%Model{} = model, kind, direction) do
    set_textarea(model.slash_ref, "")

    matches =
      model.messages
      |> Enum.filter(&message_matches?(&1, kind))

    next_id = next_message_id(model.messages, matches, model.selected_message_id, direction)

    {:noreply,
     %{
       Model.clear_suggestions(model)
       | slash_mode?: false,
         slash_text: "",
         selected_message_id: next_id || model.selected_message_id,
         conversation_scrollback_rows: 0,
         status_message: "jump #{direction} #{kind}"
     }}
  end

  defp message_matches?(message, "user"), do: message.role == "user"
  defp message_matches?(message, "assistant"), do: message.role == "assistant"

  defp message_matches?(message, "tool"),
    do: message.message_kind in ["tool", "tool_call", "tool_result"]

  defp message_matches?(message, "review"),
    do: message.message_kind in ["review", "review_request"]

  defp message_matches?(message, "error"), do: message.message_kind == "error"

  defp message_matches?(message, "final"),
    do: message.message_kind in ["summary", "direct_response", "workflow_output"]

  defp message_matches?(_message, _kind), do: true

  defp next_message_id(_messages, [], _selected_id, _direction), do: nil

  defp next_message_id(messages, matches, selected_id, direction) do
    selected_index = Enum.find_index(messages, &(&1.id == selected_id)) || -1

    candidates =
      case direction do
        :next ->
          Enum.filter(matches, fn message ->
            message_index(messages, message.id) > selected_index
          end)

        :prev ->
          Enum.filter(matches, fn message ->
            message_index(messages, message.id) < selected_index
          end)
      end

    candidates =
      if candidates == [] do
        matches
      else
        candidates
      end

    selected =
      case direction do
        :next -> List.first(candidates)
        :prev -> List.last(candidates)
      end

    selected && selected.id
  end

  defp message_index(messages, id), do: Enum.find_index(messages, &(&1.id == id)) || -1

  defp last_user_content(%Model{} = model) do
    model.messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == "user" and is_binary(&1.content) and String.trim(&1.content) != ""))
    |> case do
      nil -> nil
      message -> message.content
    end
  end

  defp hydrate_command(%Model{} = model) do
    Command.async(fn -> Commands.load_snapshot(model) end, &{:hydrated, &1})
  end

  defp render_commands(%Model{} = model) do
    if Model.graph_sources(model) == [] and RenderCache.markdown_sources(model) == [] do
      []
    else
      [Command.async(fn -> Commands.render_graphs(model) end, &{:graph_rendered, &1})]
    end
  end

  defp apply_result(%Model{} = model, result) when is_map(result) do
    fields = model |> Map.from_struct() |> Map.keys()
    struct!(model, Map.take(result, fields))
  end

  defp forward_text_key(nil, _key), do: :ok

  defp forward_text_key(ref, %Key{code: code, modifiers: modifiers})
       when is_binary(code) and is_list(modifiers) do
    ExRatatui.textarea_handle_key(ref, code, modifiers)
  end

  defp input_value(nil), do: ""
  defp input_value(ref), do: ExRatatui.textarea_get_value(ref)

  defp composer_value(%Model{composer_ref: nil} = model), do: model.composer_text
  defp composer_value(%Model{composer_ref: ref}), do: ExRatatui.textarea_get_value(ref)

  defp key_context(%Model{} = model) do
    %{
      slash_mode?: model.slash_mode?,
      composer_empty?: String.trim(composer_value(model)) == "",
      focus: model.focus,
      view_mode: model.view_mode
    }
  end

  defp clear_textareas(%Model{} = model) do
    set_textarea(model.composer_ref, "")
    set_textarea(model.slash_ref, "")
  end

  defp set_textarea(nil, _value), do: :ok
  defp set_textarea(ref, value), do: set_textarea(ref, value, [])
  defp set_textarea(nil, _value, _opts), do: :ok

  defp set_textarea(ref, value, opts) do
    :ok = ExRatatui.textarea_set_value(ref, value)

    if Keyword.get(opts, :cursor) == :end do
      line_count = max(ExRatatui.textarea_line_count(ref), 1)

      Enum.each(1..line_count, fn _line ->
        ExRatatui.textarea_handle_key(ref, "down", [])
      end)

      ExRatatui.textarea_handle_key(ref, "end", [])
    else
      :ok
    end
  end
end
