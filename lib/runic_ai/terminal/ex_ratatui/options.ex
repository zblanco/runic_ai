defmodule RunicAI.Terminal.ExRatatui.Options do
  @moduledoc """
  Option parsing for `mix runic_ai.tui`.

  These options are intentionally separate from `RunicAI.Terminal.CliOptions`
  because the TUI can start without an objective and can inspect existing runs.
  The persistence defaults are shared: local harness usage defaults to SQLite.
  """

  alias RunicAI.Agent.ModelClientResolver
  alias RunicAI.Coding.Codex.Client, as: CodexClient
  alias RunicAI.Error
  alias RunicAI.Terminal.CliOptions

  @agents [:standard, :rlm, :assistant]
  @approvals [:never, :safe, :ask]
  @modes [:read_only, :patch, :verify]
  @persistence_modes [:sqlite, :memory, :none]
  @themes [:runic, :plain]
  @graph_modes [:text, :mermaid, :mmdflux]

  @enforce_keys [:agent, :cwd, :persistence, :approve, :mode, :theme, :graph]
  defstruct [
    :sqlite_path,
    :run_id,
    :model,
    :requested_model,
    :model_resolution,
    :client,
    :client_label,
    :session_id,
    :ssh_port,
    :ssh_password,
    agent: :assistant,
    cwd: nil,
    persistence: :sqlite,
    approve: :ask,
    mode: :verify,
    theme: :runic,
    graph: :text,
    help?: false
  ]

  @type t :: %__MODULE__{}

  @spec parse([String.t()]) :: {:ok, t()} | {:error, Error.t()}
  def parse(args) when is_list(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          cwd: :string,
          persistence: :string,
          sqlite: :string,
          run: :string,
          model: :string,
          client: :string,
          mode: :string,
          approve: :string,
          session_id: :string,
          theme: :string,
          graph: :string,
          ssh: :integer,
          ssh_password: :string,
          help: :boolean
        ],
        aliases: [c: :cwd, h: :help]
      )

    with :ok <- validate_invalid(invalid),
         {:ok, cwd} <- normalize_cwd(Keyword.get(opts, :cwd, File.cwd!())),
         {:ok, persistence} <-
           normalize_persistence(Keyword.get(opts, :persistence), Keyword.get(opts, :sqlite)),
         {:ok, sqlite_path} <- normalize_sqlite_path(Keyword.get(opts, :sqlite), cwd, persistence),
         {:ok, agent} <- normalize_choice(Keyword.get(opts, :agent, "assistant"), @agents, :agent),
         {:ok, approve} <-
           normalize_choice(Keyword.get(opts, :approve, "ask"), @approvals, :approve),
         {:ok, mode} <- normalize_choice(Keyword.get(opts, :mode, "verify"), @modes, :mode),
         {:ok, theme} <- normalize_choice(theme_arg(opts), @themes, :theme),
         {:ok, graph} <- normalize_choice(Keyword.get(opts, :graph, "text"), @graph_modes, :graph),
         {:ok, client_label} <- normalize_client_label(Keyword.get(opts, :client)),
         {:ok, resolved_launch, model_resolution} <-
           ModelClientResolver.resolve(
             agent: agent,
             model: Keyword.get(opts, :model),
             client: client_module(client_label),
             client_label: client_label
           ),
         :ok <-
           validate_ssh_options(Keyword.get(opts, :ssh), Keyword.get(opts, :ssh_password)) do
      {:ok,
       %__MODULE__{
         agent: agent,
         cwd: cwd,
         persistence: persistence,
         sqlite_path: sqlite_path,
         run_id: Keyword.get(opts, :run),
         model: Keyword.get(resolved_launch, :model),
         requested_model: Keyword.get(opts, :model),
         model_resolution: model_resolution,
         client: client_arg(client_label),
         client_label: client_label,
         mode: mode,
         approve: approve,
         session_id: Keyword.get(opts, :session_id),
         theme: theme,
         graph: graph,
         ssh_port: Keyword.get(opts, :ssh),
         ssh_password: Keyword.get(opts, :ssh_password),
         help?: Keyword.get(opts, :help, false)
       }}
    end
  end

  @spec usage() :: String.t()
  def usage do
    """
    Usage:
      mix runic_ai.tui [--cwd PATH]
      mix runic_ai.tui [--agent standard|rlm|assistant] [--cwd PATH]
      mix runic_ai.tui --run RUN_ID [--sqlite PATH]
      mix runic_ai.tui --persistence memory

    Options:
      --agent standard|rlm|assistant
      --cwd PATH
      --persistence sqlite|memory|none
      --sqlite PATH
      --run RUN_ID
      --model MODEL
      --client default|codex
      --mode read_only|patch|verify
      --approve never|safe|ask
      --session-id ID
      --theme runic|plain
      --graph text|mermaid|mmdflux
      --ssh PORT
      --ssh-password PASS
    """
  end

  defp validate_invalid([]), do: :ok

  defp validate_invalid(invalid) do
    {:error,
     Error.validation("invalid runic_ai.tui options",
       source: __MODULE__,
       details: %{invalid: invalid}
     )}
  end

  defp normalize_cwd(cwd) when is_binary(cwd) and cwd != "" do
    path = Path.expand(cwd)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error,
       Error.validation("runic_ai.tui --cwd must be an existing directory",
         source: __MODULE__,
         details: %{cwd: cwd}
       )}
    end
  end

  defp normalize_cwd(cwd) do
    {:error,
     Error.validation("runic_ai.tui --cwd must be a non-empty path",
       source: __MODULE__,
       details: %{cwd: cwd}
     )}
  end

  defp normalize_persistence(nil, _sqlite_path), do: {:ok, :sqlite}

  defp normalize_persistence(value, _sqlite_path) do
    normalize_choice(value, @persistence_modes, :persistence)
  end

  defp normalize_sqlite_path(nil, cwd, :sqlite), do: {:ok, CliOptions.default_sqlite_path(cwd)}
  defp normalize_sqlite_path(nil, _cwd, _persistence), do: {:ok, nil}

  defp normalize_sqlite_path(path, _cwd, persistence) when persistence in [:memory, :none] do
    {:error,
     Error.validation("runic_ai.tui --sqlite requires --persistence sqlite",
       source: __MODULE__,
       details: %{sqlite: path, persistence: persistence}
     )}
  end

  defp normalize_sqlite_path(path, cwd, :sqlite) when is_binary(path) and path != "" do
    expanded = Path.expand(path, cwd)

    if within?(expanded, cwd) or within?(expanded, System.tmp_dir!()) do
      {:ok, expanded}
    else
      {:error,
       Error.validation("runic_ai.tui --sqlite must be inside --cwd or the system tmp dir",
         source: __MODULE__,
         details: %{sqlite: path, cwd: cwd, tmp: System.tmp_dir!()}
       )}
    end
  end

  defp normalize_sqlite_path(path, _cwd, _persistence) do
    {:error,
     Error.validation("runic_ai.tui --sqlite must be a non-empty path",
       source: __MODULE__,
       details: %{sqlite: path}
     )}
  end

  defp normalize_choice(value, choices, field) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace("-", "_")

    case Enum.find(choices, &(Atom.to_string(&1) == normalized)) do
      nil ->
        {:error,
         Error.validation("invalid runic_ai.tui #{field}",
           source: __MODULE__,
           details: %{field: field, value: value, valid: choices}
         )}

      choice ->
        {:ok, choice}
    end
  end

  defp normalize_choice(value, choices, _field) when is_atom(value) do
    if value in choices do
      {:ok, value}
    else
      {:error,
       Error.validation("invalid runic_ai.tui option",
         source: __MODULE__,
         details: %{value: value, valid: choices}
       )}
    end
  end

  defp normalize_choice(value, choices, field) do
    {:error,
     Error.validation("invalid runic_ai.tui #{field}",
       source: __MODULE__,
       details: %{field: field, value: value, valid: choices}
     )}
  end

  defp validate_ssh_options(nil, nil), do: :ok

  defp validate_ssh_options(nil, _password) do
    {:error,
     Error.validation("runic_ai.tui --ssh-password requires --ssh",
       source: __MODULE__
     )}
  end

  defp validate_ssh_options(port, password)
       when is_integer(port) and port > 0 and port < 65_536 and is_binary(password) and
              password != "",
       do: :ok

  defp validate_ssh_options(port, nil) when is_integer(port) and port > 0 and port < 65_536 do
    {:error,
     Error.validation("runic_ai.tui --ssh requires --ssh-password for local dev auth",
       source: __MODULE__,
       details: %{ssh: port}
     )}
  end

  defp validate_ssh_options(port, _password) do
    {:error,
     Error.validation("runic_ai.tui --ssh must be a TCP port",
       source: __MODULE__,
       details: %{ssh: port}
     )}
  end

  defp normalize_client_label(nil), do: {:ok, "default"}
  defp normalize_client_label(""), do: {:ok, "default"}
  defp normalize_client_label("default"), do: {:ok, "default"}
  defp normalize_client_label("req_llm"), do: {:ok, "default"}
  defp normalize_client_label("codex"), do: {:ok, "codex"}

  defp normalize_client_label(client) do
    {:error,
     Error.validation("invalid runic_ai.tui client alias",
       source: __MODULE__,
       details: %{client: client, valid: ["default", "req_llm", "codex"]}
     )}
  end

  defp client_module("codex"), do: CodexClient
  defp client_module(_client_label), do: nil

  defp client_arg("default"), do: nil
  defp client_arg(client_label), do: client_label

  defp theme_arg(opts) do
    Keyword.get(opts, :theme) || if(no_color?(), do: "plain", else: "runic")
  end

  defp no_color? do
    case System.get_env("NO_COLOR") do
      nil -> false
      "" -> false
      _value -> true
    end
  end

  defp within?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end
end
