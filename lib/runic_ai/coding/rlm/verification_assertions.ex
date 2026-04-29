defmodule RunicAI.Coding.RLM.VerificationAssertions do
  @moduledoc """
  Deterministic acceptance-check evaluators for coding RLM verification gates.

  The evaluators prefer concrete workspace state and command observations over
  model self-report. Language-specific behavior is kept as lightweight source
  assertions, not workflow templates.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.Workspace

  @spec evaluate(Workspace.t(), AcceptanceCheck.t() | map(), map()) :: AcceptanceCheck.result()
  def evaluate(%Workspace{} = workspace, check_input, context \\ %{}) when is_map(context) do
    with {:ok, check} <- AcceptanceCheck.from_input(check_input) do
      do_evaluate(workspace, check, context)
    else
      {:error, error} ->
        fallback_check =
          AcceptanceCheck.new!(:artifact_present,
            id: "invalid-check",
            required?: true,
            params: %{}
          )

        AcceptanceCheck.result(fallback_check, :fail, error.message, %{error: error.details})
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :file_exists} = check, _context) do
    path = param(check, :path)

    case resolve_file(workspace, path) do
      {:ok, resolved} ->
        AcceptanceCheck.result(check, :pass, "file exists", %{path: resolved.relative})

      {:error, message, metadata} ->
        AcceptanceCheck.result(check, :fail, message, metadata)
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :source_contains} = check, _context) do
    with {:ok, content, metadata} <- read_check_sources(workspace, check),
         {:ok, text} <- required_text(check) do
      if source_matches_text?(content, text, check) do
        AcceptanceCheck.result(check, :pass, "source contains expected text", metadata)
      else
        AcceptanceCheck.result(check, :fail, "source is missing expected text", metadata)
      end
    else
      {:error, message, metadata} -> AcceptanceCheck.result(check, :fail, message, metadata)
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :source_not_contains} = check, _context) do
    with {:ok, content, metadata} <- read_check_sources(workspace, check),
         {:ok, text} <- required_text(check) do
      if source_matches_text?(content, text, check) do
        AcceptanceCheck.result(check, :fail, "source contains forbidden text", metadata)
      else
        AcceptanceCheck.result(check, :pass, "source omits forbidden text", metadata)
      end
    else
      {:error, message, metadata} -> AcceptanceCheck.result(check, :fail, message, metadata)
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :module_exists} = check, _context) do
    module = param(check, :module) || param(check, :name)

    cond do
      not is_binary(module) or module == "" ->
        AcceptanceCheck.result(check, :fail, "module_exists requires module", %{})

      source_matches?(workspace, "defmodule #{module}") ->
        AcceptanceCheck.result(check, :pass, "module exists", %{module: module})

      true ->
        AcceptanceCheck.result(check, :fail, "module not found in workspace source", %{
          module: module
        })
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :function_exists} = check, _context) do
    function = param(check, :function) || param(check, :name)
    arity = param(check, :arity)
    needle = function_needle(function, arity)

    cond do
      is_nil(needle) ->
        AcceptanceCheck.result(check, :fail, "function_exists requires function", %{})

      source_matches?(workspace, needle) ->
        AcceptanceCheck.result(check, :pass, "function exists", %{
          function: function,
          arity: arity
        })

      true ->
        AcceptanceCheck.result(check, :fail, "function not found in workspace source", %{
          function: function,
          arity: arity
        })
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :command_passes} = check, context) do
    case expected_command(workspace, check) do
      {:ok, expected} ->
        context
        |> command_observations()
        |> find_command(expected)
        |> case do
          nil ->
            AcceptanceCheck.result(check, :skipped, "required command was not observed", %{
              command: expected.argv,
              cwd: expected.cwd_input,
              display: command_display(expected)
            })

          %{status: status} = observed when status in [:pass, "pass"] ->
            AcceptanceCheck.result(check, :pass, "command passed", %{
              command: expected.argv,
              cwd: expected.cwd_input,
              display: command_display(expected),
              observed: observed
            })

          observed ->
            AcceptanceCheck.result(check, :fail, "command did not pass", %{
              command: expected.argv,
              cwd: expected.cwd_input,
              display: command_display(expected),
              observed: observed
            })
        end

      {:error, message, metadata} ->
        AcceptanceCheck.result(check, :fail, message, metadata)
    end
  end

  defp do_evaluate(workspace, %AcceptanceCheck{type: :command_fails_with} = check, context) do
    case expected_command(workspace, check) do
      {:ok, expected} ->
        text = param(check, :text) || param(check, :contains)

        context
        |> command_observations()
        |> find_command(expected)
        |> case do
          nil ->
            AcceptanceCheck.result(
              check,
              :skipped,
              "expected failing command was not observed",
              %{
                command: expected.argv,
                cwd: expected.cwd_input,
                display: command_display(expected)
              }
            )

          observed ->
            output = output_text(observed)

            failed? =
              status(observed) in [:fail, "fail", :timeout, "timeout", :blocked, "blocked"]

            cond do
              failed? and is_binary(text) and String.contains?(output, text) ->
                AcceptanceCheck.result(check, :pass, "command failed with expected output", %{
                  command: expected.argv,
                  cwd: expected.cwd_input,
                  display: command_display(expected)
                })

              failed? and is_nil(text) ->
                AcceptanceCheck.result(check, :pass, "command failed as expected", %{
                  command: expected.argv,
                  cwd: expected.cwd_input,
                  display: command_display(expected)
                })

              true ->
                AcceptanceCheck.result(check, :fail, "command failure expectation was not met", %{
                  command: expected.argv,
                  cwd: expected.cwd_input,
                  display: command_display(expected),
                  observed: observed
                })
            end
        end

      {:error, message, metadata} ->
        AcceptanceCheck.result(check, :fail, message, metadata)
    end
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :test_count_min} = check, context) do
    min = integer_param(check, :min, 1)
    output = all_command_output(context)
    count = parse_exunit_test_count(output)

    cond do
      is_nil(count) ->
        AcceptanceCheck.result(check, :skipped, "test count was not observed", %{min: min})

      count >= min ->
        AcceptanceCheck.result(check, :pass, "observed enough tests", %{min: min, count: count})

      true ->
        AcceptanceCheck.result(check, :fail, "observed too few tests", %{min: min, count: count})
    end
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :warning_count_zero} = check, context) do
    output = all_command_output(context)
    warnings = parse_warning_count(output)

    if warnings == 0 do
      AcceptanceCheck.result(check, :pass, "no warnings observed", %{warning_count: 0})
    else
      AcceptanceCheck.result(check, :fail, "warnings were observed", %{warning_count: warnings})
    end
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :runtime_smoke} = check, context) do
    key = param(check, :id) || param(check, :name)

    context
    |> Map.get(:runtime_smokes, Map.get(context, "runtime_smokes", []))
    |> List.wrap()
    |> Enum.find(&matches_identifier?(&1, key))
    |> case do
      nil ->
        AcceptanceCheck.result(check, :skipped, "runtime smoke was not observed", %{id: key})

      smoke ->
        if status(smoke) in [:pass, "pass"] do
          AcceptanceCheck.result(check, :pass, "runtime smoke passed", %{id: key})
        else
          AcceptanceCheck.result(check, :fail, "runtime smoke did not pass", %{
            id: key,
            smoke: smoke
          })
        end
    end
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :child_status} = check, context) do
    child_id = param(check, :child_id) || param(check, :id)
    expected = normalize_status_param(param(check, :status) || :completed)

    context
    |> Map.get(:child_results, Map.get(context, "child_results", []))
    |> List.wrap()
    |> Enum.find(&matches_identifier?(&1, child_id))
    |> case do
      nil ->
        AcceptanceCheck.result(check, :skipped, "child result was not observed", %{
          child_id: child_id
        })

      child ->
        if normalize_status_param(status(child)) == expected do
          AcceptanceCheck.result(check, :pass, "child status matched", %{
            child_id: child_id,
            status: expected
          })
        else
          AcceptanceCheck.result(check, :fail, "child status did not match", %{
            child_id: child_id,
            expected: expected,
            child: child
          })
        end
    end
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :semantic_requirement} = check, _context) do
    non_blocking_check = %{check | required?: false}

    AcceptanceCheck.result(
      non_blocking_check,
      :skipped,
      "semantic requirement checks are evaluated by the semantic progress judge",
      %{
        category: :semantic_requirement_deferred,
        requirement:
          param(check, :text) || param(check, :description) || param(check, :requirement)
      }
    )
  end

  defp do_evaluate(_workspace, %AcceptanceCheck{type: :artifact_present} = check, context) do
    artifact_id = param(check, :artifact_id) || param(check, :id) || param(check, :kind)

    context
    |> Map.get(:artifacts, Map.get(context, "artifacts", []))
    |> List.wrap()
    |> Enum.find(&matches_identifier?(&1, artifact_id))
    |> case do
      nil ->
        AcceptanceCheck.result(check, :fail, "artifact was not present", %{artifact: artifact_id})

      artifact ->
        AcceptanceCheck.result(check, :pass, "artifact was present", %{artifact: artifact})
    end
  end

  defp resolve_file(_workspace, path) when not is_binary(path) or path == "",
    do: {:error, "file_exists requires path", %{path: path}}

  defp resolve_file(workspace, path) do
    case Workspace.resolve_path(workspace, path, :read) do
      {:ok, resolved} ->
        if File.regular?(resolved.path) do
          {:ok, resolved}
        else
          {:error, "path is not a regular file", %{path: resolved.relative}}
        end

      {:error, error} ->
        {:error, error.message, error.details}
    end
  end

  defp read_check_sources(workspace, check) do
    check
    |> source_selectors()
    |> Enum.reduce_while({:ok, []}, fn selector, {:ok, acc} ->
      case source_files(workspace, selector) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, message, metadata} -> {:halt, {:error, message, metadata}}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, "source check did not match any files", %{selectors: source_selectors(check)}}

      {:ok, files} ->
        files = Enum.uniq_by(files, & &1.relative)

        content =
          files
          |> Enum.map(fn file -> File.read!(file.path) end)
          |> Enum.join("\n")

        {:ok, content, %{paths: Enum.map(files, & &1.relative), file_count: length(files)}}

      error ->
        error
    end
  end

  defp source_selectors(check) do
    []
    |> Kernel.++(List.wrap(param(check, :paths)))
    |> Kernel.++(List.wrap(param(check, :path)))
    |> Kernel.++(List.wrap(param(check, :glob)))
    |> Kernel.++(List.wrap(param(check, :globs)))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["."]
      selectors -> selectors
    end
  end

  defp source_files(_workspace, selector) when not is_binary(selector) or selector == "",
    do: {:error, "source check selector must be a non-empty path or glob", %{selector: selector}}

  defp source_files(workspace, selector) do
    cond do
      glob_selector?(selector) ->
        source_glob_files(workspace, selector)

      true ->
        source_path_files(workspace, selector)
    end
  end

  defp source_path_files(workspace, path) do
    case Workspace.resolve_path(workspace, path, :read) do
      {:ok, resolved} ->
        cond do
          File.regular?(resolved.path) ->
            {:ok, [%{path: resolved.path, relative: resolved.relative}]}

          File.dir?(resolved.path) ->
            files =
              resolved.path
              |> all_regular_files()
              |> Enum.map(fn path ->
                {:ok, relative} = Workspace.relative_path(workspace, path)
                %{path: path, relative: relative}
              end)

            {:ok, files}

          true ->
            {:error, "path is not a regular file or directory", %{path: resolved.relative}}
        end

      {:error, error} ->
        {:error, error.message, error.details}
    end
  end

  defp source_glob_files(workspace, glob) do
    with :ok <- safe_relative_glob(glob),
         {:ok, resolved} <- Workspace.resolve_path(workspace, ".", :read) do
      files =
        case glob_regular_files(workspace, resolved.path, glob) do
          [] -> nested_glob_regular_files(workspace, resolved.path, glob)
          files -> files
        end

      {:ok, files}
    else
      {:error, error} ->
        {:error, error.message, error.details}

      {:error, message, metadata} ->
        {:error, message, metadata}
    end
  end

  defp safe_relative_glob(glob) do
    cond do
      Path.type(glob) == :absolute ->
        {:error, "source glob must be relative to the workspace root", %{glob: glob}}

      ".." in Path.split(glob) ->
        {:error, "source glob cannot escape the workspace root", %{glob: glob}}

      true ->
        :ok
    end
  end

  defp glob_selector?(selector) do
    String.contains?(selector, ["*", "?", "["])
  end

  defp glob_regular_files(workspace, root, glob) do
    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      case Workspace.relative_path(workspace, path) do
        {:ok, relative} -> [%{path: path, relative: relative}]
        {:error, _error} -> []
      end
    end)
  end

  defp nested_glob_regular_files(workspace, root, glob) do
    if String.starts_with?(glob, "*/") do
      []
    else
      glob_regular_files(workspace, root, "*/" <> glob)
    end
  end

  defp source_matches_text?(content, text, check) do
    cond do
      regex_check?(check) ->
        case Regex.compile(text) do
          {:ok, regex} -> Regex.match?(regex, content)
          {:error, _reason} -> false
        end

      true ->
        String.contains?(content, text)
    end
  end

  defp regex_check?(check) do
    param(check, :match) in [:regex, "regex"] or param(check, :regex) in [true, "true"]
  end

  defp required_text(check) do
    case param(check, :text) || param(check, :contains) || param(check, :substring) ||
           param(check, :pattern) do
      text when is_binary(text) and text != "" -> {:ok, text}
      text -> {:error, "source check requires text", %{text: text}}
    end
  end

  defp source_matches?(workspace, needle) do
    workspace.root
    |> all_regular_files()
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, content} -> String.contains?(content, needle)
        {:error, _reason} -> false
      end
    end)
  end

  defp all_regular_files(root) do
    root
    |> File.ls()
    |> case do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 in [".git", "_build", "deps", "node_modules"]))
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)

          cond do
            File.dir?(path) -> all_regular_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp function_needle(nil, _arity), do: nil
  defp function_needle(function, _arity) when is_binary(function), do: "def #{function}"
  defp function_needle(function, _arity) when is_atom(function), do: "def #{function}"
  defp function_needle(_function, _arity), do: nil

  defp command_observations(context) do
    []
    |> Kernel.++(List.wrap(Map.get(context, :command_results, [])))
    |> Kernel.++(List.wrap(Map.get(context, "command_results", [])))
    |> Kernel.++(List.wrap(Map.get(context, :verification_observations, [])))
    |> Kernel.++(List.wrap(Map.get(context, "verification_observations", [])))
    |> Kernel.++(List.wrap(Map.get(context, :verifications, [])))
    |> Kernel.++(List.wrap(Map.get(context, "verifications", [])))
  end

  defp find_command(observations, expected) do
    observations
    |> Enum.reverse()
    |> Enum.find(fn observation ->
      observed_command = observed_command(observation)
      command_matches?(observed_command, expected)
    end)
  end

  defp command_matches?(%{argv: observed_argv} = observed, %{argv: expected_argv} = expected)
       when is_list(observed_argv) and is_list(expected_argv) do
    observed_argv == expected_argv and cwd_matches?(observed.cwd, expected.cwd)
  end

  defp command_matches?(_observed, _expected), do: false

  defp expected_command(%Workspace{} = workspace, %AcceptanceCheck{} = check) do
    raw =
      param(check, :argv) || param(check, :command) || nested_param(check, :args, :argv) ||
        nested_param(check, :args, :command)

    with {:ok, argv} <- normalize_command(raw),
         {:ok, cwd, cwd_input} <- expected_command_cwd(workspace, check) do
      {:ok, %{argv: argv, cwd: cwd, cwd_input: cwd_input}}
    end
  end

  defp observed_command(observation) do
    raw = field(observation, :argv) || field(observation, :command)

    case normalize_command(raw) do
      {:ok, argv} -> %{argv: argv, cwd: observed_cwd(observation)}
      {:error, _message, _metadata} -> nil
    end
  end

  defp expected_command_cwd(workspace, check) do
    case param(check, :cwd) || nested_param(check, :args, :cwd) do
      nil ->
        {:ok, nil, nil}

      cwd when is_binary(cwd) and cwd != "" ->
        case Workspace.resolve_path(workspace, cwd, :read) do
          {:ok, resolved} ->
            {:ok, Path.expand(resolved.path), cwd}

          {:error, error} ->
            {:error, error.message, error.details}
        end

      cwd ->
        {:error, "command check cwd must be a string", %{cwd: cwd}}
    end
  end

  defp observed_cwd(observation) do
    case field(observation, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
      _other -> nil
    end
  end

  defp cwd_matches?(_observed, nil), do: true
  defp cwd_matches?(nil, _expected), do: false
  defp cwd_matches?(observed, expected), do: Path.expand(observed) == Path.expand(expected)

  defp normalize_command(argv) when is_list(argv) and argv != [] do
    if Enum.all?(argv, &(is_binary(&1) and &1 != "")) do
      {:ok, argv}
    else
      {:error, "command check argv must be a non-empty list of strings", %{argv: argv}}
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> split_command()
    |> case do
      [] -> {:error, "command check requires command or argv", %{command: command}}
      argv -> {:ok, argv}
    end
  end

  defp normalize_command(value) do
    {:error, "command check requires command or argv", %{command: value}}
  end

  defp split_command(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  defp command_display(%{argv: argv, cwd_input: nil}), do: Enum.join(argv, " ")

  defp command_display(%{argv: argv, cwd_input: cwd}) do
    Enum.join(argv, " ") <> " (cwd: #{cwd})"
  end

  defp all_command_output(context) do
    context
    |> command_observations()
    |> Enum.map(&output_text/1)
    |> Enum.join("\n")
  end

  defp output_text(observed) do
    field(observed, :output_preview) || field(observed, :output) || ""
  end

  defp parse_exunit_test_count(output) when is_binary(output) do
    Regex.run(~r/(\d+)\s+tests?/, output)
    |> case do
      [_, count] -> String.to_integer(count)
      _other -> nil
    end
  end

  defp parse_warning_count(output) when is_binary(output) do
    Regex.scan(~r/\bwarning:/i, output) |> length()
  end

  defp matches_identifier?(_value, nil), do: true

  defp matches_identifier?(value, id) do
    identifiers = [
      field(value, :id),
      field(value, :name),
      field(value, :kind),
      field(value, :child_id),
      field(value, :artifact_id)
    ]

    Enum.any?(identifiers, &(normalize_identifier(&1) == normalize_identifier(id)))
  end

  defp integer_param(check, key, default) do
    case param(check, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _other -> default
    end
  rescue
    ArgumentError -> default
  end

  defp normalize_identifier(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_identifier(value) when is_binary(value), do: value
  defp normalize_identifier(value), do: inspect(value)

  defp normalize_status_param(value) when is_atom(value), do: value

  defp normalize_status_param("completed"), do: :completed
  defp normalize_status_param("partial"), do: :partial
  defp normalize_status_param("blocked"), do: :blocked
  defp normalize_status_param("failed"), do: :failed
  defp normalize_status_param("needs_review"), do: :needs_review
  defp normalize_status_param("pass"), do: :pass
  defp normalize_status_param("fail"), do: :fail

  defp normalize_status_param(value), do: value

  defp status(value), do: field(value, :status)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(struct, key) when is_struct(struct), do: struct |> Map.from_struct() |> field(key)
  defp field(_value, _key), do: nil

  defp param(%AcceptanceCheck{} = check, key),
    do: Map.get(check.params, key, Map.get(check.params, Atom.to_string(key)))

  defp nested_param(%AcceptanceCheck{} = check, parent, key) do
    case param(check, parent) do
      value when is_map(value) ->
        Map.get(value, key, Map.get(value, Atom.to_string(key)))

      _value ->
        nil
    end
  end
end
