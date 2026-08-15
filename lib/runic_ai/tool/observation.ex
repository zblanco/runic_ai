defmodule RunicAI.Tool.Observation do
  @moduledoc "Projects an owned tool result into a model-visible tool-result message."

  alias RunicAI.Message
  alias RunicAI.MessageContent
  alias RunicAI.Tool.Result

  def message(%Result{status: :ok} = result) do
    Message.new!(:tool, [MessageContent.tool_result(result.call_id, result.tool, result.output)],
      name: result.tool
    )
  end

  def message(%Result{status: :error} = result) do
    Message.new!(
      :tool,
      [
        MessageContent.tool_result(result.call_id, result.tool, %{
          "error" => RunicAI.Error.encode(result.error)
        })
      ], name: result.tool)
  end
end
