defmodule RunicAI.Terminal.ExRatatui.SlashCommands do
  @moduledoc """
  Slash-command parsing for the TUI.
  """

  @definitions [
    %{name: "help", description: "Show commands", aliases: []},
    %{name: "chat", description: "Switch to chat view", aliases: []},
    %{name: "debug", description: "Switch to debug view", aliases: []},
    %{name: "new", description: "Start a fresh conversation", aliases: []},
    %{name: "switch", description: "Switch to a run or thread", aliases: ["sw"]},
    %{name: "rename", description: "Rename the selected run", aliases: []},
    %{name: "runs", description: "Focus durable runs", aliases: []},
    %{name: "search", description: "Search terminal events", aliases: ["s"]},
    %{name: "find", description: "Search current conversation", aliases: ["f"]},
    %{name: "source", description: "Search source/evidence events", aliases: []},
    %{name: "next", description: "Jump to next item kind", aliases: []},
    %{name: "prev", description: "Jump to previous item kind", aliases: []},
    %{name: "errors", description: "Show error and blocked events", aliases: []},
    %{name: "reviews", description: "Focus review details", aliases: []},
    %{name: "tools", description: "Focus tool history", aliases: []},
    %{name: "artifacts", description: "Focus artifacts", aliases: []},
    %{name: "scorecard", description: "Focus scorecards", aliases: []},
    %{name: "repairs", description: "Focus repairs", aliases: []},
    %{name: "logs", description: "Filter captured logs", aliases: []},
    %{name: "prompt", description: "Inspect prompt and conversation context", aliases: []},
    %{name: "managed", description: "Load managed workflows", aliases: []},
    %{name: "start", description: "Start a managed workflow", aliases: []},
    %{name: "resume", description: "Resume a managed workflow", aliases: []},
    %{name: "export", description: "Export selected run JSONL", aliases: []},
    %{name: "eval", description: "Load eval cohort", aliases: []},
    %{name: "graph", description: "Set graph rendering mode", aliases: []},
    %{name: "retry", description: "Retry last user turn", aliases: []},
    %{name: "regenerate", description: "Regenerate last user turn", aliases: []},
    %{name: "edit", description: "Edit last user turn", aliases: []},
    %{name: "watch", description: "Follow selected run", aliases: []},
    %{name: "pause", description: "Pause follow mode", aliases: []},
    %{name: "stop", description: "Stop active run marker", aliases: []},
    %{name: "quit", description: "Exit the TUI", aliases: ["q"]}
  ]

  @type command ::
          {:help}
          | {:chat}
          | {:debug}
          | {:new}
          | {:switch, String.t()}
          | {:rename, String.t()}
          | {:runs, String.t() | nil}
          | {:search, String.t()}
          | {:find, String.t()}
          | {:source, String.t()}
          | {:next, String.t() | nil}
          | {:prev, String.t() | nil}
          | {:errors}
          | {:reviews}
          | {:tools, String.t() | nil}
          | {:artifacts}
          | {:scorecard}
          | {:repairs}
          | {:logs, String.t() | nil}
          | {:prompt}
          | {:managed, String.t() | nil}
          | {:start, String.t() | nil}
          | {:resume, String.t() | nil}
          | {:export, String.t() | nil}
          | {:eval, String.t() | nil}
          | {:graph, String.t() | nil}
          | {:retry}
          | {:regenerate}
          | {:edit}
          | {:watch}
          | {:pause}
          | {:stop}
          | {:quit}

  @spec parse(String.t()) :: {:ok, command()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    input =
      input
      |> String.trim()
      |> String.trim_leading("/")

    case String.split(input, ~r/\s+/, parts: 2, trim: true) do
      [] -> {:error, "empty command"}
      [name] -> command(name, nil)
      [name, arg] -> command(name, String.trim(arg))
    end
  end

  @spec names() :: [String.t()]
  def names, do: Enum.map(@definitions, & &1.name)

  @spec definitions() :: [map()]
  def definitions, do: @definitions

  @spec help_text() :: String.t()
  def help_text do
    """
    /help
    /chat
    /debug
    /new
    /switch RUN_OR_THREAD
    /rename TITLE
    /runs [query]
    /search TERM
    /find TERM
    /source TERM
    /next [user|assistant|tool|review|error|final]
    /prev [user|assistant|tool|review|error|final]
    /errors
    /reviews
    /tools [name]
    /artifacts
    /scorecard
    /repairs
    /logs [level|source:TERM|clear]
    /prompt
    /managed [status]
    /start [workflow_key]
    /resume [workflow_key]
    /export [path]
    /eval [objective_status]
    /graph text|mermaid|mmdflux
    /retry
    /regenerate
    /edit
    /watch
    /pause
    /stop
    /quit
    """
  end

  defp command("help", _arg), do: {:ok, {:help}}
  defp command("chat", _arg), do: {:ok, {:chat}}
  defp command("debug", _arg), do: {:ok, {:debug}}
  defp command("new", _arg), do: {:ok, {:new}}
  defp command("switch", arg), do: required(:switch, arg)
  defp command("sw", arg), do: required(:switch, arg)
  defp command("rename", arg), do: required(:rename, arg)
  defp command("runs", arg), do: {:ok, {:runs, blank_to_nil(arg)}}
  defp command("search", arg), do: required(:search, arg)
  defp command("s", arg), do: required(:search, arg)
  defp command("find", arg), do: required(:find, arg)
  defp command("f", arg), do: required(:find, arg)
  defp command("source", arg), do: required(:source, arg)
  defp command("next", arg), do: {:ok, {:next, blank_to_nil(arg)}}
  defp command("prev", arg), do: {:ok, {:prev, blank_to_nil(arg)}}
  defp command("errors", _arg), do: {:ok, {:errors}}
  defp command("reviews", _arg), do: {:ok, {:reviews}}
  defp command("tools", arg), do: {:ok, {:tools, blank_to_nil(arg)}}
  defp command("artifacts", _arg), do: {:ok, {:artifacts}}
  defp command("scorecard", _arg), do: {:ok, {:scorecard}}
  defp command("repairs", _arg), do: {:ok, {:repairs}}
  defp command("logs", arg), do: {:ok, {:logs, blank_to_nil(arg)}}
  defp command("prompt", _arg), do: {:ok, {:prompt}}
  defp command("managed", arg), do: {:ok, {:managed, blank_to_nil(arg)}}
  defp command("start", arg), do: {:ok, {:start, blank_to_nil(arg)}}
  defp command("resume", arg), do: {:ok, {:resume, blank_to_nil(arg)}}
  defp command("export", arg), do: {:ok, {:export, blank_to_nil(arg)}}
  defp command("eval", arg), do: {:ok, {:eval, blank_to_nil(arg)}}
  defp command("graph", arg), do: {:ok, {:graph, blank_to_nil(arg)}}
  defp command("retry", _arg), do: {:ok, {:retry}}
  defp command("regenerate", _arg), do: {:ok, {:regenerate}}
  defp command("edit", _arg), do: {:ok, {:edit}}
  defp command("watch", _arg), do: {:ok, {:watch}}
  defp command("pause", _arg), do: {:ok, {:pause}}
  defp command("stop", _arg), do: {:ok, {:stop}}
  defp command("quit", _arg), do: {:ok, {:quit}}
  defp command("q", _arg), do: {:ok, {:quit}}
  defp command(name, _arg), do: {:error, "unknown command: #{name}"}

  defp required(name, nil), do: {:error, "/#{name} requires an argument"}
  defp required(name, ""), do: {:error, "/#{name} requires an argument"}
  defp required(name, arg), do: {:ok, {name, arg}}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
