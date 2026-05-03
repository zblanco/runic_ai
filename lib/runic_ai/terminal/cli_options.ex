defmodule RunicAI.Terminal.CliOptions do
  @moduledoc """
  CLI option parsing for `mix runic_ai.agent`.

  Parsing is kept separate from the Mix task so it can be tested without shell
  side effects and reused by future terminal frontends.
  """

  alias RunicAI.Error

  @agents [:standard, :rlm, :assistant]
  @details [:hidden, :collapsed, :expanded]
  @approvals [:never, :safe, :ask]
  @modes [:read_only, :patch, :verify]
  @generated_function_policies [:tier0, :tier1, :tier2_review]
  @write_policies [:none, :docs_only, :workspace_review]
  @renderers [:auto, :text, :owl]
  @color_modes [:auto, :always, :never]
  @themes [:runic, :plain]
  @progress_modes [:auto, :off]
  @unicode_modes [:auto, :always, :never]
  @graph_modes [:text, :mermaid, :mmdflux]

  @enforce_keys [
    :agent,
    :cwd,
    :detail,
    :approve,
    :interactive?,
    :mode,
    :renderer,
    :color,
    :theme,
    :progress,
    :unicode,
    :graph
  ]
  defstruct [
    :objective,
    :jsonl_path,
    :sqlite_path,
    :model,
    :client,
    :client_label,
    :max_turns,
    :max_runtime_ms,
    :max_concurrency,
    :max_llm_map_concurrency,
    :max_llm_map_calls,
    :session_id,
    async?: nil,
    input_paths: [],
    output_path: nil,
    allow_generated_functions: :tier1,
    write_policy: :docs_only,
    agent: :standard,
    cwd: nil,
    detail: :collapsed,
    approve: :ask,
    interactive?: false,
    help?: false,
    mode: :verify,
    renderer: :auto,
    color: :auto,
    theme: :runic,
    progress: :auto,
    unicode: :auto,
    graph: :text
  ]

  @type t :: %__MODULE__{}

  @spec parse([String.t()]) :: {:ok, t()} | {:error, Error.t()}
  def parse(args) when is_list(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          agent: :string,
          cwd: :string,
          model: :string,
          client: :string,
          interactive: :boolean,
          jsonl: :string,
          sqlite: :string,
          detail: :string,
          approve: :string,
          async: :boolean,
          max_turns: :integer,
          max_runtime_ms: :integer,
          max_concurrency: :integer,
          max_llm_map_concurrency: :integer,
          max_llm_map_calls: :integer,
          session_id: :string,
          mode: :string,
          input: :string,
          output: :string,
          allow_generated_functions: :string,
          write_policy: :string,
          renderer: :string,
          color: :string,
          theme: :string,
          progress: :string,
          unicode: :string,
          graph: :string,
          help: :boolean
        ],
        aliases: [c: :cwd, h: :help]
      )

    with :ok <- validate_invalid(invalid),
         {:ok, cwd} <- normalize_cwd(Keyword.get(opts, :cwd, File.cwd!())),
         {:ok, agent} <- normalize_choice(Keyword.get(opts, :agent, "standard"), @agents, :agent),
         {:ok, detail} <-
           normalize_choice(Keyword.get(opts, :detail, "collapsed"), @details, :detail),
         {:ok, approve} <-
           normalize_choice(Keyword.get(opts, :approve, "ask"), @approvals, :approve),
         {:ok, mode} <- normalize_choice(Keyword.get(opts, :mode, "verify"), @modes, :mode),
         {:ok, allow_generated_functions} <-
           normalize_choice(
             Keyword.get(opts, :allow_generated_functions, "tier1"),
             @generated_function_policies,
             :allow_generated_functions
           ),
         {:ok, write_policy} <-
           normalize_choice(
             Keyword.get(opts, :write_policy, "docs_only"),
             @write_policies,
             :write_policy
           ),
         {:ok, renderer} <-
           normalize_choice(Keyword.get(opts, :renderer, "auto"), @renderers, :renderer),
         {:ok, color} <- normalize_choice(Keyword.get(opts, :color, "auto"), @color_modes, :color),
         {:ok, theme} <- normalize_choice(Keyword.get(opts, :theme, "runic"), @themes, :theme),
         {:ok, progress} <-
           normalize_choice(Keyword.get(opts, :progress, "auto"), @progress_modes, :progress),
         {:ok, unicode} <-
           normalize_choice(Keyword.get(opts, :unicode, "auto"), @unicode_modes, :unicode),
         {:ok, graph} <- normalize_choice(Keyword.get(opts, :graph, "text"), @graph_modes, :graph),
         {:ok, input_paths} <- normalize_input_paths(Keyword.get_values(opts, :input), cwd),
         {:ok, output_path} <- normalize_workspace_path(Keyword.get(opts, :output), cwd, :output),
         {:ok, client, client_label} <- normalize_client(Keyword.get(opts, :client)),
         {:ok, jsonl_path} <- normalize_jsonl_path(Keyword.get(opts, :jsonl), cwd),
         {:ok, sqlite_path} <- normalize_sqlite_path(Keyword.get(opts, :sqlite), cwd),
         {:ok, objective} <-
           normalize_objective(
             rest,
             Keyword.get(opts, :interactive, false),
             Keyword.get(opts, :help, false)
           ),
         :ok <- validate_positive(Keyword.get(opts, :max_turns), :max_turns),
         :ok <- validate_positive(Keyword.get(opts, :max_runtime_ms), :max_runtime_ms),
         :ok <- validate_positive(Keyword.get(opts, :max_concurrency), :max_concurrency),
         :ok <-
           validate_positive(
             Keyword.get(opts, :max_llm_map_concurrency),
             :max_llm_map_concurrency
           ),
         :ok <- validate_positive(Keyword.get(opts, :max_llm_map_calls), :max_llm_map_calls) do
      {:ok,
       %__MODULE__{
         objective: objective,
         agent: agent,
         cwd: cwd,
         model: Keyword.get(opts, :model),
         client: client,
         client_label: client_label,
         interactive?: Keyword.get(opts, :interactive, false),
         jsonl_path: jsonl_path,
         sqlite_path: sqlite_path,
         detail: detail,
         approve: approve,
         async?: Keyword.get(opts, :async),
         max_turns: Keyword.get(opts, :max_turns),
         max_runtime_ms: Keyword.get(opts, :max_runtime_ms),
         max_concurrency: Keyword.get(opts, :max_concurrency),
         max_llm_map_concurrency: Keyword.get(opts, :max_llm_map_concurrency),
         max_llm_map_calls: Keyword.get(opts, :max_llm_map_calls),
         session_id: Keyword.get(opts, :session_id),
         input_paths: input_paths,
         output_path: output_path,
         allow_generated_functions: allow_generated_functions,
         write_policy: write_policy,
         help?: Keyword.get(opts, :help, false),
         mode: mode,
         renderer: renderer,
         color: color,
         theme: theme,
         progress: progress,
         unicode: unicode,
         graph: graph
       }}
    end
  end

  @spec usage() :: String.t()
  def usage do
    """
    Usage:
      mix runic_ai.agent "objective" [--agent standard|rlm|assistant] [--cwd PATH]
      mix runic_ai.agent --interactive [--agent standard] [--cwd PATH]

    Options:
      --agent standard|rlm|assistant
      --cwd PATH
      --model MODEL
      --client default|codex
      --mode read_only|patch|verify
      --input PATH
      --output PATH
      --allow-generated-functions tier0|tier1|tier2-review
      --write-policy none|docs-only|workspace-review
      --renderer auto|text|owl
      --color auto|always|never
      --theme runic|plain
      --progress auto|off
      --unicode auto|always|never
      --graph text|mermaid|mmdflux
      --interactive
      --jsonl PATH
      --sqlite PATH
      --detail hidden|collapsed|expanded
      --approve never|safe|ask
      --async / --no-async
      --max-concurrency N
      --max-llm-map-concurrency N
      --max-llm-map-calls N
      --max-turns N
      --max-runtime-ms N
      --session-id ID
    """
  end

  @spec concurrency_opts(t()) :: keyword()
  def concurrency_opts(%__MODULE__{} = options) do
    [
      async: resolved_async(options),
      max_concurrency: resolved_max_concurrency(options),
      max_llm_map_concurrency: resolved_max_llm_map_concurrency(options),
      max_llm_map_calls: resolved_max_llm_map_calls(options)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolved_async(%__MODULE__{async?: async}) when is_boolean(async), do: async
  defp resolved_async(%__MODULE__{agent: :assistant}), do: true
  defp resolved_async(%__MODULE__{}), do: nil

  defp resolved_max_concurrency(%__MODULE__{max_concurrency: concurrency})
       when is_integer(concurrency),
       do: concurrency

  defp resolved_max_concurrency(%__MODULE__{agent: :assistant}), do: 4
  defp resolved_max_concurrency(%__MODULE__{}), do: nil

  defp resolved_max_llm_map_concurrency(%__MODULE__{max_llm_map_concurrency: concurrency})
       when is_integer(concurrency),
       do: concurrency

  defp resolved_max_llm_map_concurrency(%__MODULE__{agent: :assistant}), do: 4
  defp resolved_max_llm_map_concurrency(%__MODULE__{}), do: nil

  defp resolved_max_llm_map_calls(%__MODULE__{max_llm_map_calls: calls}) when is_integer(calls),
    do: calls

  defp resolved_max_llm_map_calls(%__MODULE__{agent: :assistant}), do: 80
  defp resolved_max_llm_map_calls(%__MODULE__{}), do: nil

  defp validate_invalid([]), do: :ok

  defp validate_invalid(invalid) do
    {:error,
     Error.validation("invalid runic_ai.agent options",
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
       Error.validation("runic_ai.agent --cwd must be an existing directory",
         source: __MODULE__,
         details: %{cwd: cwd}
       )}
    end
  end

  defp normalize_cwd(cwd) do
    {:error,
     Error.validation("runic_ai.agent --cwd must be a non-empty path",
       source: __MODULE__,
       details: %{cwd: cwd}
     )}
  end

  defp normalize_choice(value, choices, field) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace("-", "_")

    case Enum.find(choices, &(Atom.to_string(&1) == normalized)) do
      nil ->
        {:error,
         Error.validation("invalid runic_ai.agent #{field}",
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
       Error.validation("invalid runic_ai.agent option",
         source: __MODULE__,
         details: %{value: value, valid: choices}
       )}
    end
  end

  defp normalize_choice(value, choices, field) do
    {:error,
     Error.validation("invalid runic_ai.agent #{field}",
       source: __MODULE__,
       details: %{field: field, value: value, valid: choices}
     )}
  end

  defp normalize_client(nil), do: {:ok, nil, "default"}
  defp normalize_client(""), do: {:ok, nil, "default"}
  defp normalize_client("default"), do: {:ok, nil, "default"}
  defp normalize_client("req_llm"), do: {:ok, nil, "default"}
  defp normalize_client("codex"), do: {:ok, :codex, "codex"}

  defp normalize_client(client) do
    {:error,
     Error.validation("invalid runic_ai.agent client alias",
       source: __MODULE__,
       details: %{client: client, valid: ["default", "req_llm", "codex"]}
     )}
  end

  defp normalize_jsonl_path(nil, _cwd), do: {:ok, nil}

  defp normalize_jsonl_path(path, cwd) when is_binary(path) and path != "" do
    expanded = Path.expand(path, cwd)

    if within?(expanded, cwd) or within?(expanded, System.tmp_dir!()) do
      {:ok, expanded}
    else
      {:error,
       Error.validation("runic_ai.agent --jsonl must be inside --cwd or the system tmp dir",
         source: __MODULE__,
         details: %{jsonl: path, cwd: cwd, tmp: System.tmp_dir!()}
       )}
    end
  end

  defp normalize_jsonl_path(path, _cwd) do
    {:error,
     Error.validation("runic_ai.agent --jsonl must be a non-empty path",
       source: __MODULE__,
       details: %{jsonl: path}
     )}
  end

  defp normalize_sqlite_path(nil, _cwd), do: {:ok, nil}

  defp normalize_sqlite_path(path, cwd) when is_binary(path) and path != "" do
    expanded = Path.expand(path, cwd)

    if within?(expanded, cwd) or within?(expanded, System.tmp_dir!()) do
      {:ok, expanded}
    else
      {:error,
       Error.validation("runic_ai.agent --sqlite must be inside --cwd or the system tmp dir",
         source: __MODULE__,
         details: %{sqlite: path, cwd: cwd, tmp: System.tmp_dir!()}
       )}
    end
  end

  defp normalize_sqlite_path(path, _cwd) do
    {:error,
     Error.validation("runic_ai.agent --sqlite must be a non-empty path",
       source: __MODULE__,
       details: %{sqlite: path}
     )}
  end

  defp normalize_input_paths(paths, cwd) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case normalize_workspace_path(path, cwd, :input) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_workspace_path(nil, _cwd, _field), do: {:ok, nil}
  defp normalize_workspace_path("", _cwd, _field), do: {:ok, nil}

  defp normalize_workspace_path(path, cwd, field) when is_binary(path) do
    expanded = Path.expand(path, cwd)

    if within?(expanded, cwd) do
      {:ok, Path.relative_to(expanded, cwd)}
    else
      {:error,
       Error.validation("runic_ai.agent --#{field} must be inside --cwd",
         source: __MODULE__,
         details: %{field: field, path: path, cwd: cwd}
       )}
    end
  end

  defp normalize_workspace_path(path, _cwd, field) do
    {:error,
     Error.validation("runic_ai.agent --#{field} must be a path string",
       source: __MODULE__,
       details: %{field: field, path: path}
     )}
  end

  defp normalize_objective(rest, _interactive?, true), do: {:ok, Enum.join(rest, " ")}

  defp normalize_objective(rest, true, _help?), do: {:ok, Enum.join(rest, " ")}

  defp normalize_objective([], false, _help?) do
    {:error,
     Error.validation("runic_ai.agent requires an objective or --interactive",
       source: __MODULE__,
       details: %{}
     )}
  end

  defp normalize_objective(rest, false, _help?), do: {:ok, Enum.join(rest, " ")}

  defp validate_positive(nil, _field), do: :ok
  defp validate_positive(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(value, field) do
    {:error,
     Error.validation("runic_ai.agent #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp within?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end
end
