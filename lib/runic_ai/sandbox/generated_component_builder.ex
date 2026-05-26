defmodule RunicAI.Sandbox.GeneratedComponentBuilder do
  @moduledoc """
  Writes, tests, and repairs generated component code inside a sandbox session.

  The builder does not generate source on its own. Callers provide proposed
  source/test files and, optionally, a repair callback. This keeps generation,
  execution, and promotion as separate observable phases.
  """

  alias RunicAI.Coding.SandboxSessionRegistry
  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent

  @default_timeout_ms 30_000
  @default_max_output_bytes 16_384

  @type file_spec :: %{required(:path) => String.t(), required(:content) => String.t()}
  @type result :: %{
          required(:component) => GeneratedComponent.t(),
          required(:status) => :verified | :failed,
          required(:attempts) => [map()],
          required(:source_artifacts) => [map()],
          required(:test_artifacts) => [map()]
        }

  @spec run(GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, result()} | {:error, Error.t()}
  def run(component_input, opts \\ []) when is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         {:ok, registry} <- required_opt(opts, :registry),
         {:ok, session_id} <-
           required_string(Keyword.get(opts, :sandbox_session_id), :sandbox_session_id),
         {:ok, source_files} <- files(Keyword.get(opts, :source_files, []), :source_files),
         {:ok, test_files} <- files(Keyword.get(opts, :test_files, []), :test_files),
         {:ok, test_command} <- test_command(component, opts),
         {:ok, write_result} <- write_files(registry, session_id, source_files, test_files) do
      loop(
        component,
        registry,
        session_id,
        test_command,
        write_result,
        [],
        opts
      )
    end
  end

  defp loop(component, registry, session_id, test_command, write_result, attempts, opts) do
    attempt_number = length(attempts) + 1

    with {:ok, execution} <- exec_test(registry, session_id, component, test_command, opts) do
      attempt = attempt(attempt_number, test_command, execution)
      attempts = attempts ++ [attempt]

      if passed?(execution) do
        verified(component, test_command, write_result, attempts, execution)
      else
        maybe_repair(
          component,
          registry,
          session_id,
          test_command,
          write_result,
          attempts,
          execution,
          opts
        )
      end
    end
  end

  defp maybe_repair(
         component,
         registry,
         session_id,
         test_command,
         write_result,
         attempts,
         execution,
         opts
       ) do
    max_attempts = Keyword.get(opts, :max_repair_attempts, 0) + 1
    repair_fun = Keyword.get(opts, :repair_fun)

    cond do
      length(attempts) >= max_attempts ->
        failed(component, test_command, write_result, attempts, execution)

      is_function(repair_fun, 1) ->
        repair_context = %{
          component: component,
          attempt: length(attempts),
          execution: execution,
          attempts: attempts,
          source_artifacts: write_result.source_artifacts,
          test_artifacts: write_result.test_artifacts
        }

        with {:ok, repair_files} <- normalize_repair(repair_fun.(repair_context)),
             {:ok, repair_write_result} <-
               write_files(
                 registry,
                 session_id,
                 Map.get(repair_files, :source_files, []),
                 Map.get(repair_files, :test_files, [])
               ) do
          write_result =
            %{
              source_artifacts:
                merge_artifacts(
                  write_result.source_artifacts,
                  repair_write_result.source_artifacts
                ),
              test_artifacts:
                merge_artifacts(write_result.test_artifacts, repair_write_result.test_artifacts)
            }

          loop(component, registry, session_id, test_command, write_result, attempts, opts)
        end

      true ->
        failed(component, test_command, write_result, attempts, execution)
    end
  end

  defp verified(component, test_command, write_result, attempts, execution) do
    update_component(component, :verified, write_result, %{
      status: :pass,
      command: test_command,
      attempts: length(attempts),
      last_execution: execution,
      diagnostics: diagnostics(execution)
    })
    |> case do
      {:ok, component} ->
        {:ok,
         %{
           component: component,
           status: :verified,
           attempts: attempts,
           source_artifacts: write_result.source_artifacts,
           test_artifacts: write_result.test_artifacts
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp failed(component, test_command, write_result, attempts, execution) do
    update_component(component, :draft, write_result, %{
      status: :failed,
      command: test_command,
      attempts: length(attempts),
      last_execution: execution,
      diagnostics: diagnostics(execution)
    })
    |> case do
      {:ok, component} ->
        {:ok,
         %{
           component: component,
           status: :failed,
           attempts: attempts,
           source_artifacts: write_result.source_artifacts,
           test_artifacts: write_result.test_artifacts
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp update_component(component, promotion_status, write_result, verification) do
    GeneratedComponent.validate(%{
      component
      | source_artifacts: write_result.source_artifacts,
        test_artifacts: write_result.test_artifacts,
        verification: verification,
        promotion_status: promotion_status
    })
  end

  defp exec_test(registry, session_id, component, test_command, opts) do
    request = %{
      runtime: Keyword.get(opts, :test_runtime, test_runtime(component)),
      mode: :script,
      source: test_command,
      cwd: Keyword.get(opts, :sandbox_cwd, "/workspace"),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
      network: :disabled
    }

    SandboxSessionRegistry.exec(registry, session_id, request)
  end

  defp test_runtime(%GeneratedComponent{language: :python}), do: :bash
  defp test_runtime(%GeneratedComponent{language: :node}), do: :bash
  defp test_runtime(%GeneratedComponent{language: :elixir}), do: :bash
  defp test_runtime(%GeneratedComponent{language: :bash}), do: :bash
  defp test_runtime(_component), do: :bash

  defp write_files(registry, session_id, source_files, test_files) do
    with {:ok, source_artifacts} <- write_file_group(registry, session_id, source_files, :source),
         {:ok, test_artifacts} <- write_file_group(registry, session_id, test_files, :test) do
      {:ok, %{source_artifacts: source_artifacts, test_artifacts: test_artifacts}}
    end
  end

  defp write_file_group(registry, session_id, files, kind) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case SandboxSessionRegistry.write_file(registry, session_id, file.path, file.content) do
        {:ok, ref} ->
          artifact =
            ref
            |> Map.put_new(:path, file.path)
            |> Map.put(:kind, kind)

          {:cont, {:ok, acc ++ [artifact]}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        {:error, reason} ->
          {:halt, {:error, Error.from_reason(reason, source: __MODULE__)}}
      end
    end)
  end

  defp attempt(attempt_number, test_command, execution) do
    %{
      attempt: attempt_number,
      command: test_command,
      status: if(passed?(execution), do: :pass, else: :failed),
      execution: execution,
      diagnostics: diagnostics(execution)
    }
  end

  defp diagnostics(execution) when is_map(execution) do
    %{
      status: Map.get(execution, :status),
      exit_status: Map.get(execution, :exit_status),
      stdout_preview: Map.get(execution, :stdout, ""),
      stderr_preview: Map.get(execution, :stderr, ""),
      duration_ms: Map.get(execution, :duration_ms),
      backend: Map.get(execution, :backend),
      isolation_level: Map.get(execution, :isolation_level)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp passed?(execution) when is_map(execution) do
    Map.get(execution, :status) in [:ok, "ok", :completed, "completed"] and
      Map.get(execution, :exit_status, 0) == 0
  end

  defp merge_artifacts(left, right), do: Enum.uniq_by(left ++ right, &artifact_identity/1)

  defp artifact_identity(artifact) when is_map(artifact),
    do: Map.get(artifact, :ref) || Map.get(artifact, "ref") || Map.get(artifact, :path)

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        {:error,
         Error.validation("generated component builder requires #{key}",
           source: __MODULE__,
           details: %{field: key}
         )}

      value ->
        {:ok, value}
    end
  end

  defp required_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp required_string(value, field) do
    {:error,
     Error.validation("generated component builder requires #{field}",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp test_command(%GeneratedComponent{} = component, opts) do
    opts
    |> Keyword.get(:test_command)
    |> fallback(first_verification_command(component))
    |> required_string(:test_command)
  end

  defp first_verification_command(%GeneratedComponent{verification: verification}) do
    verification
    |> get_in([:commands])
    |> fallback(get_in(verification, ["commands"]))
    |> List.wrap()
    |> List.first()
  end

  defp files(files, field) when is_list(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case file(file, field) do
        {:ok, file} -> {:cont, {:ok, acc ++ [file]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp files(files, field) do
    {:error,
     Error.validation("generated component builder #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: files}
     )}
  end

  defp file({path, content}, field), do: file(%{path: path, content: content}, field)

  defp file(file, field) when is_map(file) do
    path = Map.get(file, :path, Map.get(file, "path"))
    content = Map.get(file, :content, Map.get(file, "content"))

    with {:ok, path} <- required_string(path, "#{field}.path"),
         {:ok, content} <- required_string(content, "#{field}.content") do
      {:ok, %{path: path, content: content, kind: Map.get(file, :kind, Map.get(file, "kind"))}}
    end
  end

  defp file(file, field) do
    {:error,
     Error.validation("generated component builder #{field} entries must be maps or tuples",
       source: __MODULE__,
       details: %{field: field, value: file}
     )}
  end

  defp normalize_repair({:ok, repair}) when is_map(repair) do
    with {:ok, source_files} <- files(Map.get(repair, :source_files, []), :source_files),
         {:ok, test_files} <- files(Map.get(repair, :test_files, []), :test_files) do
      {:ok, %{source_files: source_files, test_files: test_files}}
    end
  end

  defp normalize_repair({:error, %Error{} = error}), do: {:error, error}

  defp normalize_repair({:error, reason}),
    do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp normalize_repair(other) do
    {:error,
     Error.validation("generated component repair_fun must return {:ok, %{source_files: files}}",
       source: __MODULE__,
       details: %{result: other}
     )}
  end

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value
end
