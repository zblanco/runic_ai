defmodule RunicAI.WorkflowTestStep do
  @moduledoc false

  def delayed_increment(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    Process.sleep(milliseconds)
    milliseconds + 1
  end
end
