defmodule RunicAI.Livebook.Setup do
  @moduledoc false

  @default_model "openai:gpt-5.4-mini"
  @default_output_tokens 800

  def default_model, do: @default_model

  def inputs(opts \\ []) do
    model =
      opts
      |> Keyword.get(:model, System.get_env("RUNIC_AI_MODEL") || @default_model)
      |> to_string()

    api_key_input =
      Kino.Input.password("OPENAI_API_KEY",
        default: System.get_env("OPENAI_API_KEY") || ""
      )

    model_input = Kino.Input.text("Model", default: model)
    tokens_input = Kino.Input.number("Max output tokens", default: @default_output_tokens)

    Kino.Layout.grid(
      [
        Kino.Markdown.new("""
        **Provider setup**

        These notebooks default to `#{@default_model}` through ReqLLM. Paste an OpenAI
        key or set `OPENAI_API_KEY` before running the live model cells.
        """),
        api_key_input,
        model_input,
        tokens_input
      ],
      columns: 1
    )
    |> Kino.render()

    %{api_key: api_key_input, model: model_input, max_output_tokens: tokens_input}
  end

  def read_model!(inputs) when is_map(inputs) do
    api_key = read_string(inputs.api_key)

    if api_key != "" do
      System.put_env("OPENAI_API_KEY", api_key)
    end

    inputs.model
    |> read_string()
    |> model_for()
  end

  def read_max_output_tokens(inputs) when is_map(inputs) do
    case Kino.Input.read(inputs.max_output_tokens) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> round(value)
      _ -> @default_output_tokens
    end
  end

  def model_for(model) when is_binary(model) do
    case String.trim(model) do
      "" -> ReqLLM.model!(@default_model)
      model_id -> ReqLLM.model!(model_id)
    end
  end

  def model_for(model), do: model

  def llm_opts(model, opts \\ []) do
    output_tokens =
      opts
      |> Keyword.get(
        :max_output_tokens,
        Keyword.get(opts, :max_completion_tokens, @default_output_tokens)
      )
      |> normalize_tokens()

    opts =
      opts
      |> Keyword.drop([:max_output_tokens, :max_completion_tokens])
      |> Keyword.put_new(output_token_key(model), output_tokens)

    opts
  end

  def require_openai_key! do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        raise """
        OPENAI_API_KEY is not set.

        Paste a key in the setup input above, set an `OPENAI_API_KEY` Livebook secret,
        or export the environment variable before running this cell.
        """

      "" ->
        raise "OPENAI_API_KEY is empty."

      _key ->
        :ok
    end
  end

  defp read_string(input) do
    input
    |> Kino.Input.read()
    |> to_string()
    |> String.trim()
  end

  defp normalize_tokens(tokens) when is_integer(tokens) and tokens > 0, do: tokens
  defp normalize_tokens(tokens) when is_float(tokens) and tokens > 0, do: round(tokens)
  defp normalize_tokens(_tokens), do: @default_output_tokens

  defp output_token_key(_model), do: :max_tokens
end

defmodule RunicAI.Livebook.Cytoscape do
  @moduledoc false

  use Kino.JS

  def new(elements, opts \\ []) when is_list(elements) do
    data = %{
      elements: elements,
      height: Keyword.get(opts, :height, 520),
      layout:
        Keyword.get(opts, :layout, %{
          name: "breadthfirst",
          directed: true,
          padding: 24,
          spacingFactor: 1.25
        })
    }

    Kino.JS.new(__MODULE__, data,
      export: fn payload -> {"json", payload.elements} end
    )
  end

  asset "main.js" do
    """
    export async function init(ctx, data) {
      const root = ctx.root;
      root.innerHTML = "";

      const container = document.createElement("div");
      container.style.height = `${data.height || 520}px`;
      container.style.width = "100%";
      container.style.border = "1px solid rgba(148, 163, 184, 0.35)";
      container.style.borderRadius = "8px";
      container.style.background = "rgba(15, 23, 42, 0.03)";
      root.appendChild(container);

      await ctx.importJS("https://cdn.jsdelivr.net/npm/cytoscape@3.28.1/dist/cytoscape.min.js");

      const cy = cytoscape({
        container,
        elements: data.elements || [],
        style: [
          {
            selector: "node",
            style: {
              "background-color": "data(background_color)",
              "shape": "data(shape)",
              "label": "data(name)",
              "font-size": "11px",
              "text-wrap": "wrap",
              "text-max-width": "120px",
              "text-valign": "center",
              "text-halign": "center",
              "color": "#0f172a",
              "border-width": 1,
              "border-color": "rgba(15, 23, 42, 0.3)",
              "width": "label",
              "height": "label",
              "padding": "12px"
            }
          },
          {
            selector: "edge",
            style: {
              "curve-style": "bezier",
              "target-arrow-shape": "triangle",
              "line-color": "#64748b",
              "target-arrow-color": "#64748b",
              "width": 2,
              "label": "data(label)",
              "font-size": "9px",
              "text-rotation": "autorotate"
            }
          }
        ],
        layout: data.layout || { name: "breadthfirst", directed: true }
      });

      cy.fit(undefined, 24);
    }
    """
  end
end

defmodule RunicAI.Livebook.WorkflowViz do
  @moduledoc false

  alias Runic.Workflow

  def mermaid(%Workflow{} = workflow, opts \\ []) do
    workflow
    |> Workflow.to_mermaid(
      direction: Keyword.get(opts, :direction, :LR),
      include_memory: Keyword.get(opts, :include_memory, false),
      title: Keyword.get(opts, :title)
    )
    |> Kino.Mermaid.new(
      caption: Keyword.get(opts, :caption),
      download: Keyword.get(opts, :download, true)
    )
  end

  def cytoscape(%Workflow{} = workflow, opts \\ []) do
    workflow
    |> Workflow.to_cytoscape()
    |> RunicAI.Livebook.Cytoscape.new(opts)
  end

  def tabs(%Workflow{} = workflow, opts \\ []) do
    Kino.Layout.tabs(
      Mermaid: mermaid(workflow, opts),
      Cytoscape: cytoscape(workflow, opts),
      "Raw productions": Kino.Tree.new(Workflow.raw_productions(workflow))
    )
  end
end

defmodule RunicAI.Livebook.Tools do
  @moduledoc false

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Tool.Registry

  def once_per_loop_selector do
    fn %TurnRequest{} = turn_request, %Registry{} = registry ->
      if tool_result_seen?(turn_request), do: [], else: registry.tools
    end
  end

  defp tool_result_seen?(%TurnRequest{state: %{conversation: %{messages: messages}}})
       when is_list(messages) do
    Enum.any?(messages, &match?(%{role: :tool}, &1))
  end

  defp tool_result_seen?(_turn_request), do: false
end

defmodule RunicAI.Livebook.DevEndpoints do
  @moduledoc false

  @default_url "http://localhost:8080"
  @timeout 5_000

  def default_url, do: System.get_env("LIVEBOOK_URL") || @default_url

  def check(notebook_file, opts \\ []) do
    livebook_url =
      opts
      |> Keyword.get(:url, default_url())
      |> to_string()
      |> String.trim_trailing("/")

    notebook_file = Path.expand(notebook_file)
    source = File.read(notebook_file)

    [
      request(livebook_url, :open, %{file: notebook_file}),
      request(livebook_url, :sync, %{file: notebook_file}),
      restamp_request(livebook_url, source)
    ]
  end

  def rows(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      %{
        endpoint: check.endpoint,
        ok?: check.ok?,
        status: check.status,
        detail: check.detail
      }
    end)
  end

  defp restamp_request(livebook_url, {:ok, source}) do
    request(livebook_url, :restamp, %{old_source: source, new_source: source})
  end

  defp restamp_request(_livebook_url, {:error, reason}) do
    %{
      endpoint: "/dev/restamp",
      ok?: false,
      status: "file_error",
      detail: inspect(reason)
    }
  end

  defp request(livebook_url, endpoint, body) do
    endpoint_path = "/dev/#{endpoint}"

    case Req.post("#{livebook_url}#{endpoint_path}", json: body, receive_timeout: @timeout) do
      {:ok, %{status: status, body: response_body}} ->
        %{
          endpoint: endpoint_path,
          ok?: status in 200..299,
          status: status,
          detail: response_detail(response_body)
        }

      {:error, reason} ->
        %{
          endpoint: endpoint_path,
          ok?: false,
          status: "request_error",
          detail: Exception.message(reason)
        }
    end
  rescue
    exception ->
      %{
        endpoint: "/dev/#{endpoint}",
        ok?: false,
        status: "exception",
        detail: Exception.message(exception)
      }
  end

  defp response_detail(%{"path" => path}), do: path
  defp response_detail(%{"status" => status}), do: status
  defp response_detail(%{"source" => source}), do: "source bytes: #{byte_size(source)}"
  defp response_detail(body), do: inspect(body)
end

defmodule RunicAI.Livebook.Chat do
  @moduledoc false

  alias Runic.Workflow
  alias RunicAI.Agent.State
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  def start(recipe, recipe_opts, opts \\ []) when is_atom(recipe) and is_list(recipe_opts) do
    state_pid =
      Kino.start_child!({
        Agent,
        fn ->
          %{
            recipe: recipe,
            recipe_opts: recipe_opts,
            state: Keyword.get(opts, :state),
            workflow: Keyword.get(opts, :workflow),
            review_request: nil,
            wait: nil,
            events: []
          }
        end
      })

    frame = Kino.Frame.new()

    message_form =
      Kino.Control.form(
        [
          message:
            Kino.Input.textarea("Message",
              default: Keyword.get(opts, :initial_message, "")
            )
        ],
        submit: "Send",
        reset_on_submit: [:message]
      )

    review_form =
      Kino.Control.form(
        [
          status:
            Kino.Input.text("Review status",
              default: "approved"
            ),
          edited_value:
            Kino.Input.textarea("Edited value",
              default: ""
            )
        ],
        submit: "Resume review",
        reset_on_submit: [:edited_value]
      )

    render_transcript(frame, state_pid)

    stream = Kino.Control.tagged_stream(message: message_form, review: review_form)

    Kino.listen(stream, fn
      {:message, %{data: %{message: message}, origin: origin}} ->
        message = String.trim(to_string(message))

        if message != "" do
          run_user_turn(state_pid, frame, message, origin)
        end

      {:review, %{data: data, origin: origin}} ->
        run_review_turn(state_pid, frame, data, origin)
    end)

    Kino.Layout.grid(
      [
        frame,
        Kino.Layout.tabs(Message: message_form, Review: review_form)
      ],
      columns: 1,
      gap: 12
    )
  end

  def start_integrated(recipe, recipe_opts, opts \\ [])
      when is_atom(recipe) and is_list(recipe_opts) do
    workflow = recipe.new(recipe_opts)

    state_pid =
      Kino.start_child!({
        Agent,
        fn ->
          %{
            recipe: recipe,
            recipe_opts: recipe_opts,
            workflow: workflow,
            events: []
          }
        end
      })

    frame = Kino.Frame.new()

    form =
      Kino.Control.form(
        [
          agent_id:
            Kino.Input.text("Agent id",
              default: Keyword.get(opts, :agent_id, "agent")
            ),
          message:
            Kino.Input.textarea("Message",
              default: Keyword.get(opts, :initial_message, "")
            )
        ],
        submit: "Send",
        reset_on_submit: [:message]
      )

    render_transcript(frame, state_pid)

    Kino.listen(form, fn %{data: %{agent_id: agent_id, message: message}, origin: origin} ->
      message = String.trim(to_string(message))

      if message != "" do
        run_integrated_turn(state_pid, frame, to_string(agent_id), message, origin)
      end
    end)

    Kino.Layout.grid([frame, form], columns: 1, gap: 12)
  end

  defp run_user_turn(state_pid, frame, message, origin) do
    Agent.get_and_update(state_pid, fn state ->
      input =
        case state.state do
          %State{} = agent_state -> %{state: agent_state, user: message}
          _ -> %{user: message}
        end

      {workflow, event} = run_recipe(state.recipe, state.recipe_opts, input)
      state = update_from_workflow(state, workflow, message, event)
      {state, state}
    end)

    render_transcript(frame, state_pid, to: origin)
  end

  defp run_review_turn(state_pid, frame, data, origin) do
    Agent.get_and_update(state_pid, fn state ->
      status =
        data
        |> Map.get(:status, "approved")
        |> normalize_review_status()

      edited_value =
        data
        |> Map.get(:edited_value, "")
        |> to_string()
        |> String.trim()

      input =
        case state.review_request do
          %ReviewRequest{} = review_request ->
            review_decision = %{
              resume_key: review_request.resume_key,
              status: status
            }

            review_decision =
              if status == :edited and edited_value != "" do
                Map.put(review_decision, :edited_value, edited_value)
              else
                review_decision
              end

            %{state: state.state, review_decision: review_decision}

          _ ->
            nil
        end

      {workflow, event} =
        if input do
          run_recipe(state.recipe, state.recipe_opts, input)
        else
          {state.workflow, %{kind: :notice, text: "No pending review request."}}
        end

      state = update_from_workflow(state, workflow, "review: #{status}", event)
      {state, state}
    end)

    render_transcript(frame, state_pid, to: origin)
  end

  defp run_integrated_turn(state_pid, frame, agent_id, message, origin) do
    Agent.get_and_update(state_pid, fn state ->
      workflow =
        Workflow.react_until_satisfied(state.workflow, %{
          agent_id: agent_id,
          user: message
        })

      event = integrated_event(state.recipe, workflow, agent_id)

      events =
        state.events ++
          [
            %{role: :user, agent_id: agent_id, content: message},
            event
          ]

      state = %{state | workflow: workflow, events: events}
      {state, state}
    end)

    render_transcript(frame, state_pid, to: origin)
  end

  defp run_recipe(recipe, recipe_opts, input) do
    workflow =
      if function_exported?(recipe, :react_until_resolution, 3) do
        apply(recipe, :react_until_resolution, [recipe_opts, input, []])
      else
        recipe
        |> apply(:new, [recipe_opts])
        |> Workflow.react_until_satisfied(input)
      end

    {workflow, workflow_event(recipe, workflow)}
  rescue
    exception ->
      {nil, %{kind: :error, text: Exception.message(exception)}}
  end

  defp update_from_workflow(state, nil, message, event) do
    %{state | events: state.events ++ [%{role: :user, content: message}, event]}
  end

  defp update_from_workflow(state, workflow, message, event) do
    new_state = latest(recipe_module(state), workflow, :latest_state)
    review_request = latest(recipe_module(state), workflow, :latest_review_request)
    wait = latest(recipe_module(state), workflow, :latest_wait)

    %{
      state
      | state: new_state || state.state,
        workflow: workflow,
        review_request: review_request,
        wait: wait,
        events: state.events ++ [%{role: :user, content: message}, event]
    }
  end

  defp workflow_event(recipe, workflow) do
    cond do
      review_request = latest(recipe, workflow, :latest_review_request) ->
        %{kind: :review, value: review_request}

      wait = latest(recipe, workflow, :latest_wait) ->
        %{kind: :wait, value: wait}

      tool_results = latest(recipe, workflow, :latest_tool_results) ->
        reply = latest(recipe, workflow, :latest_reply_text)
        %{kind: :tools, value: tool_results, reply: reply}

      reply = latest(recipe, workflow, :latest_reply_text) ->
        %{role: :assistant, content: reply}

      true ->
        %{kind: :notice, text: "Workflow completed without a visible reply."}
    end
  end

  defp integrated_event(recipe, workflow, agent_id) do
    cond do
      review_request = latest(recipe, workflow, :latest_review_request, [agent_id]) ->
        %{kind: :review, agent_id: agent_id, value: review_request}

      wait = latest(recipe, workflow, :latest_wait, [agent_id]) ->
        %{kind: :wait, agent_id: agent_id, value: wait}

      reply = latest(recipe, workflow, :latest_reply_text, [agent_id]) ->
        %{role: :assistant, agent_id: agent_id, content: reply}

      true ->
        %{kind: :notice, agent_id: agent_id, text: "No visible emission."}
    end
  end

  defp render_transcript(frame, state_pid, opts \\ []) do
    state = Agent.get(state_pid, & &1)

    markdown =
      state.events
      |> Enum.map_join("\n\n", &event_markdown/1)
      |> case do
        "" ->
          """
          _The conversation will appear here._

          Tool results, review requests, waits, and assistant messages render as
          workflow events rather than hidden side effects.
          """

        rendered ->
          rendered
      end

    Kino.Frame.render(frame, Kino.Markdown.new(markdown), opts)
  end

  defp event_markdown(%{role: :user, agent_id: agent_id, content: content}) do
    """
    **You -> #{agent_id}**

    #{blockquote(content)}
    """
  end

  defp event_markdown(%{role: :assistant, agent_id: agent_id, content: content}) do
    """
    **#{agent_id}**

    #{blockquote(content)}
    """
  end

  defp event_markdown(%{role: :user, content: content}) do
    """
    **You**

    #{blockquote(content)}
    """
  end

  defp event_markdown(%{role: :assistant, content: content}) do
    """
    **Assistant**

    #{blockquote(content)}
    """
  end

  defp event_markdown(%{kind: :tools, value: results, reply: reply}) do
    rows =
      Enum.map_join(List.wrap(results), "\n", fn result ->
        "- `#{tool_result_name(result)}`: `#{tool_result_status(result)}`"
      end)

    reply_md =
      if is_binary(reply) do
        "\n\n**Assistant**\n\n#{blockquote(reply)}"
      else
        ""
      end

    """
    **Tool batch**

    #{rows}#{reply_md}
    """
  end

  defp event_markdown(%{kind: :review, value: %ReviewRequest{} = review_request}) do
    """
    **Review required**

    - checkpoint: `#{inspect(review_request.checkpoint)}`
    - resume key: `#{review_request.resume_key}`

    Submit the Review form with `approved`, `edited`, or `rejected`.
    """
  end

  defp event_markdown(%{kind: :wait, value: %Wait{} = wait}) do
    """
    **Wait requested**

    - reason: `#{inspect(wait.reason)}`
    - resume key: `#{wait.resume_key}`
    """
  end

  defp event_markdown(%{kind: :error, text: text}) do
    """
    **Error**

    #{blockquote(text)}
    """
  end

  defp event_markdown(%{kind: :notice, text: text}) do
    """
    **Notice**

    #{blockquote(text)}
    """
  end

  defp event_markdown(other) do
    """
    **Workflow event**

    ```elixir
    #{inspect(other, pretty: true)}
    ```
    """
  end

  defp blockquote(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", &"> #{&1}")
  end

  defp tool_result_name(%{request: %{tool_name: tool_name}}), do: tool_name
  defp tool_result_name(%{tool_name: tool_name}), do: tool_name
  defp tool_result_name(%{name: name}), do: name
  defp tool_result_name(_result), do: "tool"

  defp tool_result_status(%{status: status}), do: status
  defp tool_result_status(_result), do: "completed"

  defp recipe_module(%{recipe: recipe}), do: recipe

  defp normalize_review_status(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "approved" -> :approved
      "approve" -> :approved
      "edited" -> :edited
      "edit" -> :edited
      "rejected" -> :rejected
      "reject" -> :rejected
      _other -> :approved
    end
  end

  defp latest(recipe, workflow, function, extra_args \\ []) do
    cond do
      is_nil(workflow) ->
        nil

      function_exported?(recipe, function, 1 + length(extra_args)) ->
        apply(recipe, function, [workflow | extra_args])

      function_exported?(recipe, function, 1) and extra_args == [] ->
        apply(recipe, function, [workflow])

      true ->
        nil
    end
  end
end
