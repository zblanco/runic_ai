defmodule RunicAI.RLM.Robustness.DeterministicChecks do
  @moduledoc """
  Deterministic workspace checks for robustness project scenarios.
  """

  alias RunicAI.RLM.Robustness.ProjectScenario

  @excerpt_limit 4_000

  @spec evaluate(ProjectScenario.t(), Path.t(), keyword()) :: map()
  def evaluate(%ProjectScenario{} = scenario, root, opts \\ []) when is_binary(root) do
    checks =
      Enum.map(scenario.deterministic_checks, fn check ->
        evaluate_check(root, normalize_check(check), opts)
      end)

    %{
      status: status(checks),
      total: length(checks),
      passed: Enum.count(checks, &(&1.status == :pass)),
      failed: Enum.count(checks, &(&1.status == :fail)),
      skipped: Enum.count(checks, &(&1.status == :skipped)),
      required_skipped: Enum.count(checks, &required_skipped?/1),
      optional_skipped: Enum.count(checks, &optional_skipped?/1),
      checks: checks
    }
  end

  @spec workspace_files(Path.t()) :: [String.t()]
  def workspace_files(root) when is_binary(root), do: files(root)

  @spec workspace_fingerprints(Path.t()) :: %{String.t() => String.t()}
  def workspace_fingerprints(root) when is_binary(root) do
    root
    |> files()
    |> Map.new(fn path ->
      {path, root |> Path.join(path) |> File.read!() |> sha256()}
    end)
  end

  defp evaluate_check(root, %{type: :file_exists, path: path} = check, _opts) do
    pass_fail(check, File.exists?(Path.join(root, path)), "file exists", "file missing")
  end

  defp evaluate_check(root, %{type: :source_contains, text: text} = check, _opts) do
    contents = matching_contents(root, check)

    pass_fail(
      check,
      Enum.any?(contents, &String.contains?(&1, text)),
      "source text found",
      "source text missing"
    )
  end

  defp evaluate_check(root, %{type: :source_not_contains, text: text} = check, _opts) do
    contents = matching_contents(root, check)

    pass_fail(
      check,
      Enum.all?(contents, &(not String.contains?(&1, text))),
      "forbidden source text absent",
      "forbidden source text present"
    )
  end

  defp evaluate_check(root, %{type: :test_count_min, min: min} = check, _opts) do
    count =
      root
      |> Path.join("test/**/*_test.exs")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.map(&Regex.scan(~r/\btest\s+"/, &1))
      |> Enum.map(&length/1)
      |> Enum.sum()

    check
    |> pass_fail(count >= min, "test count #{count} >= #{min}", "test count #{count} < #{min}")
    |> put_in([:details, :actual], count)
  end

  defp evaluate_check(root, %{type: :command_passes, argv: [exe | args]} = check, opts) do
    timeout = Map.get(check, :timeout, Keyword.get(opts, :command_timeout, 120_000))

    try do
      case run_command(root, exe, args) do
        {%{stdout: _stdout, stderr: _stderr} = output, 0} ->
          %{
            check: check,
            status: :pass,
            message: "command passed",
            details: output_details(output, timeout)
          }

        {%{stdout: _stdout, stderr: _stderr} = output, status} ->
          %{
            check: check,
            status: :fail,
            message: "command failed with #{status}",
            details: Map.put(output_details(output, timeout), :status, status)
          }
      end
    rescue
      exception ->
        %{
          check: check,
          status: :fail,
          message: "command raised",
          details: %{exception: Exception.message(exception), timeout: timeout}
        }
    end
  end

  defp evaluate_check(
         root,
         %{type: :command_passes_if_env, argv: [_exe | _args], env: env} = check,
         opts
       )
       when is_binary(env) do
    if System.get_env(env) in [nil, "", "0", "false", "FALSE"] do
      %{
        check: check,
        status: :skipped,
        message: "optional command skipped; set #{env}=1 to run",
        details: %{env: env, skipped?: true, optional?: true}
      }
    else
      root
      |> evaluate_check(Map.put(check, :type, :command_passes), opts)
      |> put_in([:details, :optional_env], env)
    end
  end

  defp evaluate_check(
         root,
         %{type: :changed_file_count_between, min: min, max: max} = check,
         opts
       ) do
    if Keyword.has_key?(opts, :baseline_files) do
      baseline = Keyword.fetch!(opts, :baseline_files)
      changed = changed_files(root, baseline, Keyword.get(opts, :baseline_file_fingerprints))
      count = length(changed)

      check
      |> pass_fail(
        count >= min and count <= max,
        "changed file count #{count} within range",
        "changed file count #{count} outside range"
      )
      |> put_in([:details, :changed_files], changed)
    else
      %{
        check: check,
        status: :fail,
        message: "changed-file baseline missing",
        details: %{changed_files: [], min: min, max: max}
      }
    end
  end

  defp evaluate_check(_root, check, _opts) do
    %{check: check, status: :skipped, message: "unsupported check type", details: %{}}
  end

  defp matching_contents(root, %{path: path}) when is_binary(path) do
    absolute = Path.join(root, path)
    if File.regular?(absolute), do: [File.read!(absolute)], else: []
  end

  defp matching_contents(root, %{glob: glob}) when is_binary(glob) do
    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&File.read!/1)
  end

  defp matching_contents(_root, _check), do: []

  defp pass_fail(check, true, pass_message, _fail_message),
    do: %{check: check, status: :pass, message: pass_message, details: %{}}

  defp pass_fail(check, false, _pass_message, fail_message),
    do: %{check: check, status: :fail, message: fail_message, details: %{}}

  defp status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == :fail)) -> :fail
      Enum.any?(checks, &required_skipped?/1) -> :review
      true -> :pass
    end
  end

  defp required_skipped?(%{status: :skipped} = check), do: not optional_skipped?(check)
  defp required_skipped?(_check), do: false

  defp optional_skipped?(%{status: :skipped, details: %{optional?: true}}), do: true
  defp optional_skipped?(_check), do: false

  defp normalize_check(check) when is_map(check) do
    check
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.update(:type, nil, &normalize_type/1)
  end

  defp normalize_key("type"), do: :type
  defp normalize_key("path"), do: :path
  defp normalize_key("glob"), do: :glob
  defp normalize_key("text"), do: :text
  defp normalize_key("min"), do: :min
  defp normalize_key("max"), do: :max
  defp normalize_key("argv"), do: :argv
  defp normalize_key("env"), do: :env
  defp normalize_key("timeout"), do: :timeout
  defp normalize_key(key) when is_binary(key), do: key

  defp normalize_key(key), do: key

  defp normalize_type("file_exists"), do: :file_exists
  defp normalize_type("source_contains"), do: :source_contains
  defp normalize_type("source_not_contains"), do: :source_not_contains
  defp normalize_type("test_count_min"), do: :test_count_min
  defp normalize_type("command_passes"), do: :command_passes
  defp normalize_type("command_passes_if_env"), do: :command_passes_if_env
  defp normalize_type("changed_file_count_between"), do: :changed_file_count_between
  defp normalize_type(type), do: type

  defp files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(&generated_runtime_artifact?/1)
    |> Enum.sort()
  end

  defp changed_files(root, _baseline_files, baseline_fingerprints)
       when is_map(baseline_fingerprints) do
    current_fingerprints = workspace_fingerprints(root)

    current_fingerprints
    |> Enum.filter(fn {path, fingerprint} ->
      Map.get(baseline_fingerprints, path) != fingerprint
    end)
    |> Enum.map(fn {path, _fingerprint} -> path end)
    |> Enum.reject(&generated_runtime_artifact?/1)
    |> Enum.sort()
  end

  defp changed_files(root, baseline_files, _baseline_fingerprints) do
    current = files(root)
    current -- baseline_files
  end

  defp generated_runtime_artifact?(path) when is_binary(path) do
    case Path.split(path) do
      [dir | _rest] when dir in ["_build", "deps", "tmp"] -> true
      [".elixir_ls" | _rest] -> true
      _parts -> false
    end
  end

  defp run_command(root, exe, args) do
    capture_dir =
      Path.join(root, "tmp/rlm-deterministic-check-#{System.unique_integer([:positive])}")

    stdout_path = Path.join(capture_dir, "stdout.log")
    stderr_path = Path.join(capture_dir, "stderr.log")
    File.mkdir_p!(capture_dir)

    {_shell_output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "out=$1; err=$2; shift 2; \"$@\" >\"$out\" 2>\"$err\"",
          "runic_check",
          stdout_path,
          stderr_path,
          exe | args
        ],
        cd: root,
        env: [{"MIX_ENV", "test"}]
      )

    output = %{
      stdout: read_capture(stdout_path),
      stderr: read_capture(stderr_path)
    }

    File.rm_rf(capture_dir)
    {output, status}
  end

  defp read_capture(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  defp output_details(%{stdout: stdout, stderr: stderr}, timeout) do
    combined = [stdout, stderr] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

    %{
      output: tail(combined),
      stdout_excerpt: tail(stdout),
      stderr_excerpt: tail(stderr),
      output_truncated?: truncated?(combined),
      stdout_truncated?: truncated?(stdout),
      stderr_truncated?: truncated?(stderr),
      timeout: timeout
    }
  end

  defp tail(output) when is_binary(output) do
    if byte_size(output) > @excerpt_limit do
      "..." <> binary_part(output, byte_size(output) - @excerpt_limit, @excerpt_limit)
    else
      output
    end
  end

  defp truncated?(output) when is_binary(output), do: byte_size(output) > @excerpt_limit

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
