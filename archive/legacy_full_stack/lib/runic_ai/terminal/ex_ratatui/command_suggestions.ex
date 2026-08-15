defmodule RunicAI.Terminal.ExRatatui.CommandSuggestions do
  @moduledoc """
  Slash-command suggestions and completion for the ExRatatui composer.
  """

  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.SlashCommands

  @managed_statuses ~w(pending active paused failed scheduled completed cancelled waiting review)
  @eval_statuses ~w(objective_satisfied objective_incomplete objective_blocked unknown)
  @graph_modes ~w(text mermaid mmdflux)
  @log_filters ~w(debug info notice warning error critical alert emergency clear)

  @type suggestion :: %{
          value: String.t(),
          replacement: String.t(),
          label: String.t(),
          description: String.t(),
          kind: atom()
        }

  @spec suggest(Model.t(), String.t()) :: [suggestion()]
  def suggest(%Model{} = model, input) when is_binary(input) do
    input = normalize_input(input)

    case split_command(input) do
      {:command, prefix} ->
        command_suggestions(prefix)

      {:argument, command, prefix} ->
        argument_suggestions(model, command, prefix)
    end
  end

  @spec selected([suggestion()], non_neg_integer()) :: suggestion() | nil
  def selected([], _index), do: nil

  def selected(suggestions, index) do
    Enum.at(suggestions, rem(max(index, 0), length(suggestions)))
  end

  @spec next_index([suggestion()], non_neg_integer(), :next | :prev) :: non_neg_integer()
  def next_index([], _index, _direction), do: 0

  def next_index(suggestions, index, :next), do: rem(index + 1, length(suggestions))

  def next_index(suggestions, index, :prev) do
    rem(index - 1 + length(suggestions), length(suggestions))
  end

  defp command_suggestions(prefix) do
    SlashCommands.definitions()
    |> Enum.filter(fn command ->
      starts?(command.name, prefix) or Enum.any?(command.aliases, &starts?(&1, prefix))
    end)
    |> Enum.map(fn command ->
      %{
        value: command.name,
        replacement: "/#{command.name} ",
        label: "/#{command.name}",
        description: command.description,
        kind: :command
      }
    end)
  end

  defp argument_suggestions(_model, "graph", prefix),
    do: fixed_arguments("graph", @graph_modes, prefix)

  defp argument_suggestions(_model, "managed", prefix),
    do: fixed_arguments("managed", @managed_statuses, prefix)

  defp argument_suggestions(_model, "eval", prefix),
    do: fixed_arguments("eval", @eval_statuses, prefix)

  defp argument_suggestions(_model, "logs", prefix),
    do: fixed_arguments("logs", @log_filters, prefix)

  defp argument_suggestions(%Model{} = model, "runs", prefix) do
    model.runs
    |> Enum.map(fn run ->
      label = "#{run.id} #{run.objective || run.workflow_name || ""}" |> String.trim()
      argument("runs", run.id, label, "select run", prefix)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp argument_suggestions(%Model{} = model, "switch", prefix) do
    model.runs
    |> Enum.map(fn run ->
      label = "#{run.id} #{run.objective || run.workflow_name || ""}" |> String.trim()
      argument("switch", run.id, label, "switch conversation", prefix)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp argument_suggestions(%Model{} = model, "tools", prefix) do
    model.tool_calls
    |> Enum.map(& &1.tool_name)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&argument("tools", &1, &1, "filter tool history", prefix))
    |> Enum.reject(&is_nil/1)
  end

  defp argument_suggestions(%Model{} = model, command, prefix)
       when command in ["start", "resume"] do
    model.managed_workflows
    |> Enum.map(&(&1.workflow_key || &1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&argument(command, &1, &1, "managed workflow key", prefix))
    |> Enum.reject(&is_nil/1)
  end

  defp argument_suggestions(_model, _command, _prefix), do: []

  defp fixed_arguments(command, values, prefix) do
    values
    |> Enum.map(&argument(command, &1, &1, "argument", prefix))
    |> Enum.reject(&is_nil/1)
  end

  defp argument(command, value, label, description, prefix) do
    if starts?(value, prefix) do
      %{
        value: value,
        replacement: "/#{command} #{value}",
        label: label,
        description: description,
        kind: :argument
      }
    end
  end

  defp normalize_input(input) do
    input
    |> String.trim_leading()
    |> then(fn
      "/" <> _rest = command -> command
      other -> "/" <> other
    end)
  end

  defp split_command(input) do
    case String.split(String.trim_leading(input, "/"), ~r/\s+/, parts: 2, trim: false) do
      [""] -> {:command, ""}
      [prefix] -> {:command, prefix}
      [command, arg] -> {:argument, command, String.trim_leading(arg)}
    end
  end

  defp starts?(value, prefix) when is_binary(value) and is_binary(prefix) do
    String.starts_with?(String.downcase(value), String.downcase(prefix))
  end
end
