defmodule RunicAI.LLM.RequestResultTest do
  use ExUnit.Case, async: true

  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.Message

  test "text and structured requests use one round-trippable request model" do
    request =
      Request.new!("openai:gpt-test", "Return a score",
        parameters: %{temperature: 0.2, max_tokens: 100},
        output: %{
          type: "object",
          properties: %{score: %{type: "integer"}},
          required: ["score"],
          additional_properties: false
        },
        metadata: %{trace_ref: "trace-1"},
        extensions: %{openai: %{service_tier: "auto"}}
      )

    encoded = Request.encode(request)
    assert {:ok, ^request} = encoded |> Jason.encode!() |> Jason.decode!() |> Request.decode()
    assert request.output.type == :object
  end

  test "unknown generation parameters are rejected" do
    assert {:error, [%{path: ["parameters"], message: message}]} =
             Request.new("openai:gpt-test", "hello", parameters: %{provider_secret: true})

    assert message =~ "unsupported"
  end

  test "one result model carries text, structured output, usage, and evidence" do
    result =
      Result.new!(Message.assistant("Done"),
        object: %{score: 7},
        usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
        evidence: %{provider: "openai", model: "gpt-test", finish_reason: "stop"},
        warnings: ["fixture"]
      )

    encoded = Result.encode(result)
    assert {:ok, ^result} = encoded |> Jason.encode!() |> Jason.decode!() |> Result.decode()
    assert Result.text(result) == "Done"
    assert result.object == %{"score" => 7}
  end
end
