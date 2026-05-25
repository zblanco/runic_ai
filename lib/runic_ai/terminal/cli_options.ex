defmodule RunicAI.Terminal.CliOptions do
  @moduledoc """
  CLI option parsing for `mix runic_ai.agent`.

  Parsing is kept separate from the Mix task so it can be tested without shell
  side effects and reused by future terminal frontends.
  """

  alias RunicAI.Agent.ModelClientResolver
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
  @persistence_modes [:sqlite, :memory, :none]

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
    :graph,
    :persistence
  ]
  defstruct [
    :objective,
    :jsonl_path,
    :sqlite_path,
    :persistence,
    :model,
    :requested_model,
    :model_resolution,
    :client,
    :client_label,
    :max_turns,
    :max_runtime_ms,
    :max_objective_iterations,
    :proposal_timeout_ms,
    :repair?,
    :max_repairs,
    :seed_project_generation?,
    :max_concurrency,
    :max_llm_map_concurrency,
    :max_llm_map_calls,
    :session_id,
    :profile,
    async?: nil,
    input_paths: [],
    output_path: nil,
    toolsets: [],
    disabled_tools: [],
    allowed_tools: [],
    tool_config: %{},
    objective_loop?: false,
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
    input_values = repeated_option_values(args, "input")
    toolset_values = repeated_option_values(args, "toolsets")
    disabled_tool_values = repeated_option_values(args, "disable-tool")
    allowed_tool_values = repeated_option_values(args, "allow-tool")
    tool_config_values = repeated_option_values(args, "tool-config")

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
          persistence: :string,
          detail: :string,
          approve: :string,
          async: :boolean,
          max_turns: :integer,
          max_runtime_ms: :integer,
          max_objective_iterations: :integer,
          proposal_timeout_ms: :integer,
          objective_loop: :boolean,
          repair: :boolean,
          max_repairs: :integer,
          seed_project_generation: :boolean,
          max_concurrency: :integer,
          max_llm_map_concurrency: :integer,
          max_llm_map_calls: :integer,
          session_id: :string,
          profile: :string,
          toolsets: :string,
          disable_tool: :string,
          allow_tool: :string,
          tool_config: :string,
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
         {:ok, input_paths} <- normalize_input_paths(input_values, cwd),
         {:ok, output_path} <- normalize_workspace_path(Keyword.get(opts, :output), cwd, :output),
         {:ok, profile} <- normalize_optional_profile(Keyword.get(opts, :profile)),
         {:ok, toolsets} <-
           normalize_csv_values(toolset_values ++ Keyword.get_values(opts, :toolsets)),
         {:ok, disabled_tools} <-
           normalize_csv_values(disabled_tool_values ++ Keyword.get_values(opts, :disable_tool)),
         {:ok, allowed_tools} <-
           normalize_csv_values(allowed_tool_values ++ Keyword.get_values(opts, :allow_tool)),
         {:ok, tool_config} <-
           normalize_tool_config(tool_config_values ++ Keyword.get_values(opts, :tool_config)),
         {:ok, client, client_label} <- normalize_client(Keyword.get(opts, :client)),
         {:ok, resolved_launch, model_resolution} <-
           ModelClientResolver.resolve(
             agent: agent,
             model: Keyword.get(opts, :model),
             client: client,
             client_label: client_label
           ),
         {:ok, jsonl_path} <- normalize_jsonl_path(Keyword.get(opts, :jsonl), cwd),
         {:ok, persistence} <-
           normalize_persistence(Keyword.get(opts, :persistence), Keyword.get(opts, :sqlite)),
         {:ok, sqlite_path} <- normalize_sqlite_path(Keyword.get(opts, :sqlite), cwd, persistence),
         {:ok, objective} <-
           normalize_objective(
             rest,
             Keyword.get(opts, :interactive, false),
             Keyword.get(opts, :help, false)
           ),
         :ok <- validate_positive(Keyword.get(opts, :max_turns), :max_turns),
         :ok <- validate_positive(Keyword.get(opts, :max_runtime_ms), :max_runtime_ms),
         :ok <-
           validate_positive(
             Keyword.get(opts, :max_objective_iterations),
             :max_objective_iterations
           ),
         :ok <- validate_positive(Keyword.get(opts, :proposal_timeout_ms), :proposal_timeout_ms),
         :ok <- validate_non_negative(Keyword.get(opts, :max_repairs), :max_repairs),
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
         model: Keyword.get(resolved_launch, :model),
         requested_model: Keyword.get(opts, :model),
         model_resolution: model_resolution,
         client: client,
         client_label: Keyword.get(resolved_launch, :client_label, client_label),
         interactive?: Keyword.get(opts, :interactive, false),
         jsonl_path: jsonl_path,
         sqlite_path: sqlite_path,
         persistence: persistence,
         detail: detail,
         approve: approve,
         async?: Keyword.get(opts, :async),
         max_turns: Keyword.get(opts, :max_turns),
         max_runtime_ms: Keyword.get(opts, :max_runtime_ms),
         max_objective_iterations: Keyword.get(opts, :max_objective_iterations),
         proposal_timeout_ms: Keyword.get(opts, :proposal_timeout_ms),
         objective_loop?: Keyword.get(opts, :objective_loop, false),
         repair?: Keyword.get(opts, :repair),
         max_repairs: Keyword.get(opts, :max_repairs),
         seed_project_generation?: Keyword.get(opts, :seed_project_generation, false),
         max_concurrency: Keyword.get(opts, :max_concurrency),
         max_llm_map_concurrency: Keyword.get(opts, :max_llm_map_concurrency),
         max_llm_map_calls: Keyword.get(opts, :max_llm_map_calls),
         session_id: Keyword.get(opts, :session_id),
         profile: profile,
         toolsets: toolsets,
         disabled_tools: disabled_tools,
         allowed_tools: allowed_tools,
         tool_config: tool_config,
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
      --persistence sqlite|memory|none
      --sqlite PATH
      --detail hidden|collapsed|expanded
      --approve never|safe|ask
      --async / --no-async
      --max-concurrency N
      --max-llm-map-concurrency N
      --max-llm-map-calls N
      --max-turns N
      --max-runtime-ms N
      --objective-loop / --no-objective-loop
      --max-objective-iterations N
      --proposal-timeout-ms N
      --repair / --no-repair
      --max-repairs N
      --seed-project-generation / --no-seed-project-generation
      --session-id ID
      --profile safe|coding-read|coding-patch|coding-verify|local-workbench|research|full-local
      --toolsets a,b,c
      --disable-tool NAME
      --allow-tool NAME
      --tool-config key=value
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

  defp normalize_optional_profile(nil), do: {:ok, nil}
  defp normalize_optional_profile(""), do: {:ok, nil}

  defp normalize_optional_profile(profile) when is_binary(profile) do
    {:ok, profile |> String.trim() |> String.replace("_", "-")}
  end

  defp normalize_optional_profile(profile), do: {:ok, profile}

  defp normalize_csv_values(values) when is_list(values) do
    {:ok,
     values
     |> Enum.flat_map(fn
       value when is_binary(value) -> String.split(value, [",", "\n"], trim: true)
       value -> [to_string(value)]
     end)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))
     |> Enum.uniq()}
  end

  defp normalize_tool_config(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      case parse_tool_config(value) do
        {:ok, key_path, parsed_value} ->
          {:cont, {:ok, put_nested_config(acc, key_path, parsed_value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp parse_tool_config(value) when is_binary(value) do
    case String.split(value, "=", parts: 2) do
      [key, config_value] ->
        key_path =
          key
          |> String.trim()
          |> String.split(".", trim: true)

        if key_path == [] do
          invalid_tool_config(value)
        else
          {:ok, key_path, parse_tool_config_value(String.trim(config_value))}
        end

      _other ->
        invalid_tool_config(value)
    end
  end

  defp parse_tool_config(value), do: invalid_tool_config(value)

  defp parse_tool_config_value("true"), do: true
  defp parse_tool_config_value("false"), do: false

  defp parse_tool_config_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp put_nested_config(config, [key], value), do: Map.put(config, key, value)

  defp put_nested_config(config, [key | rest], value) do
    Map.update(config, key, put_nested_config(%{}, rest, value), fn nested ->
      put_nested_config(Map.new(nested || %{}), rest, value)
    end)
  end

  defp invalid_tool_config(value) do
    {:error,
     Error.validation("invalid runic_ai.agent --tool-config",
       source: __MODULE__,
       details: %{tool_config: value, expected: "key=value"}
     )}
  end

  defp normalize_client(nil), do: {:ok, nil, "default"}
  defp normalize_client(""), do: {:ok, nil, "default"}
  defp normalize_client("default"), do: {:ok, nil, "default"}
  defp normalize_client("req_llm"), do: {:ok, nil, "default"}
  defp normalize_client("codex"), do: {:ok, RunicAI.Coding.Codex.Client, "codex"}

  defp normalize_client(client) do
    {:error,
     Error.validation("invalid runic_ai.agent client alias",
       source: __MODULE__,
       details: %{client: client, valid: ["default", "req_llm", "codex"]}
     )}
  end

  defp repeated_option_values(args, option_name) do
    long = "--#{option_name}"
    prefix = long <> "="

    args
    |> Enum.reduce({[], false}, fn
      arg, {values, true} ->
        {values ++ [arg], false}

      ^long, {values, false} ->
        {values, true}

      arg, {values, false} when is_binary(arg) ->
        if String.starts_with?(arg, prefix) do
          {values ++ [String.replace_prefix(arg, prefix, "")], false}
        else
          {values, false}
        end
    end)
    |> elem(0)
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

  @spec default_sqlite_path(Path.t()) :: Path.t()
  def default_sqlite_path(cwd), do: Path.join([cwd, ".runic_ai", "runs.db"])

  defp normalize_persistence(nil, _sqlite_path), do: {:ok, :sqlite}

  defp normalize_persistence(value, _sqlite_path) do
    normalize_choice(value, @persistence_modes, :persistence)
  end

  defp normalize_sqlite_path(nil, cwd, :sqlite), do: {:ok, default_sqlite_path(cwd)}
  defp normalize_sqlite_path(nil, _cwd, _persistence), do: {:ok, nil}

  defp normalize_sqlite_path(path, _cwd, persistence) when persistence in [:memory, :none] do
    {:error,
     Error.validation("runic_ai.agent --sqlite requires --persistence sqlite",
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
       Error.validation("runic_ai.agent --sqlite must be inside --cwd or the system tmp dir",
         source: __MODULE__,
         details: %{sqlite: path, cwd: cwd, tmp: System.tmp_dir!()}
       )}
    end
  end

  defp normalize_sqlite_path(path, _cwd, _persistence) do
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

  defp validate_non_negative(nil, _field), do: :ok
  defp validate_non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(value, field) do
    {:error,
     Error.validation("runic_ai.agent #{field} must be a non-negative integer",
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
