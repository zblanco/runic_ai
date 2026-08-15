defmodule RunicAI.Phase7Fixtures do
  @moduledoc false

  alias RunicAI.Prompt
  alias RunicAI.Tool.Definition

  def weather_tool do
    Definition.new!(
      name: "get_weather",
      description: "Get weather for a city",
      parameter_schema: [location: [type: :string, required: true]],
      executor: fn %{location: location} ->
        {:ok, %{location: location, forecast: "sunny"}}
      end
    )
  end

  def weather_client do
    fn _model, %Prompt{messages: messages}, _opts ->
      last_user = last_user_content(messages)
      location = if String.contains?(last_user, "Berlin"), do: "Berlin", else: "Paris"

      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: location},
                 id: "call_1"
               )
             ],
             "Let me check."
           )}

        _tool_message ->
          {:ok, RunicAI.LLM.TestClient.result("#{location} is sunny.")}
      end
    end
  end

  def color_memory_client do
    fn _model, %Prompt{messages: messages}, _opts ->
      response =
        cond do
          String.contains?(last_user_content(messages), "favorite color") ->
            "noted"

          String.contains?(last_user_content(messages), "What color") and
              Enum.any?(messages, &String.contains?(&1.content, "vermilion")) ->
            "vermilion"

          true ->
            "unknown"
        end

      {:ok, RunicAI.LLM.TestClient.result(response)}
    end
  end

  def keyword_reply_client(replies, fallback \\ "unknown") when is_list(replies) do
    fn _model, %Prompt{messages: messages}, _opts ->
      last_user = last_user_content(messages)

      response =
        Enum.find_value(replies, fallback, fn {needle, reply} ->
          if String.contains?(last_user, needle), do: reply
        end)

      {:ok, RunicAI.LLM.TestClient.result(response)}
    end
  end

  defp last_user_content(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      nil -> ""
      message -> message.content
    end
  end
end
