defmodule RunicAI.Sandbox.GeneratedComponentProof do
  @moduledoc """
  Proves proposed generated-component files inside a `LitterBox` session.

  This runner is intentionally generation-agnostic. Callers provide the
  generated source and tests as data; the runner materializes them only through
  sandbox request files, executes the verification command through attach, and
  records the neutral attach summary as promotion evidence.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent
  alias LitterBox.AttachBridge
  alias LitterBox.Capabilities
  alias LitterBox.Session

  @default_timeout_ms 30_000
  @default_max_output_bytes 16_384

  @type file_spec :: %{required(:path) => String.t(), required(:content) => String.t()}
  @type result :: %{
          required(:id) => String.t(),
          required(:component) => GeneratedComponent.t(),
          required(:status) => :verified | :failed,
          required(:command) => String.t(),
          required(:attach_summary) => map(),
          required(:source_artifacts) => [map()],
          required(:test_artifacts) => [map()],
          required(:session) => map(),
          required(:capabilities) => map(),
          required(:cleanup) => map()
        }

  @spec run(GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, result()} | {:error, Error.t()}
  def run(component_input, opts \\ []) when is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         {:ok, source_files} <- files(Keyword.get(opts, :source_files, []), :source_files),
         {:ok, test_files} <- files(Keyword.get(opts, :test_files, []), :test_files),
         {:ok, command} <- verification_command(component, opts),
         {:ok, session} <- open_session(component, opts) do
      case require_attach_support(session) do
        :ok ->
          run_in_session(component, source_files, test_files, command, session, opts)

        {:error, %Error{} = error} ->
          _cleanup = cleanup(session, nil, opts)
          {:error, error}
      end
    end
  end

  defp run_in_session(component, source_files, test_files, command, session, opts) do
    proof_id = Keyword.get(opts, :id, "generated_component_proof:#{component.id}")
    materialized_files = materialized_files(source_files, test_files)
    request = attach_request(component, command, materialized_files, proof_id, session, opts)
    attach_result = attach_fun(opts).(session, request, attach_opts(opts))

    {result, handle} =
      case attach_result do
        {:ok, handle} ->
          summary = AttachBridge.summarize(handle)

          proof_result(
            proof_id,
            component,
            command,
            summary,
            source_files,
            test_files,
            session
          )
          |> then(&{&1, handle})

        {:error, error} ->
          {{:error, normalize_error(error)}, nil}
      end

    cleanup = cleanup(session, handle, opts)

    case result do
      {:ok, proof} -> {:ok, Map.put(proof, :cleanup, cleanup)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp proof_result(proof_id, component, command, summary, source_files, test_files, session) do
    source_artifacts = artifact_summaries(source_files, :source)
    test_artifacts = artifact_summaries(test_files, :test)
    status = if proof_passed?(summary), do: :verified, else: :failed

    verification = %{
      status: if(status == :verified, do: :pass, else: :failed),
      command: command,
      proof_id: proof_id,
      attach_summary: attach_verification_summary(summary),
      diagnostics: diagnostics(summary)
    }

    with {:ok, component} <-
           GeneratedComponent.validate(%{
             component
             | promotion_status: if(status == :verified, do: :verified, else: :draft),
               source_artifacts: source_artifacts,
               test_artifacts: test_artifacts,
               verification: verification,
               metadata: proof_metadata(component.metadata, summary, session)
           }) do
      {:ok,
       %{
         id: proof_id,
         component: component,
         status: status,
         command: command,
         attach_summary: summary,
         source_artifacts: source_artifacts,
         test_artifacts: test_artifacts,
         session: session_summary(session),
         capabilities: capability_summary(session.capabilities),
         cleanup: %{}
       }}
    end
  end

  defp proof_passed?(summary) do
    Map.get(summary, :status) == :pass and Map.get(summary, :exit_status) in [0, nil] and
      not Map.get(summary, :missing_terminal?, false)
  end

  defp attach_request(component, command, files, proof_id, session, opts) do
    %{
      runtime: Keyword.get(opts, :test_runtime, :bash),
      mode: :script,
      source: command,
      cwd: Keyword.get(opts, :sandbox_cwd, default_cwd(session)),
      files: files,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
      network: Keyword.get(opts, :network, :disabled),
      metadata: %{
        generated_component_id: component.id,
        generated_component_language: component.language,
        generated_component_runtime: component.runtime,
        proof_id: proof_id
      }
    }
  end

  defp default_cwd(%Session{backend: :just_bash}), do: "."

  defp default_cwd(%Session{} = session) do
    session.metadata[:default_cwd] ||
      session.metadata["default_cwd"] ||
      Capabilities.default_cwd(session.capabilities) ||
      "/workspace"
  end

  defp open_session(component, opts) do
    sandbox = Keyword.get(opts, :sandbox, component.sandbox_profile || :local_code)
    spec = Keyword.get(opts, :sandbox_spec, [])
    session_opts = Keyword.get(opts, :session_opts, Keyword.take(opts, [:profile, :server]))

    opts
    |> open_session_fun()
    |> apply_open_session(sandbox, spec, session_opts)
    |> normalize_sandbox_result()
  end

  defp apply_open_session(fun, sandbox, spec, session_opts) when is_function(fun, 3),
    do: fun.(sandbox, spec, session_opts)

  defp require_attach_support(%Session{capabilities: capabilities}) do
    if Capabilities.attach_supported?(capabilities) do
      :ok
    else
      {:error,
       Error.validation("generated component proof requires sandbox attach support",
         source: __MODULE__,
         details: %{attach_mode: Capabilities.attach_mode(capabilities)}
       )}
    end
  end

  defp cleanup(session, handle, opts) do
    %{
      attach_closed?: close_attach(handle, opts),
      session_closed?: close_session(session, opts)
    }
  end

  defp close_attach(nil, _opts), do: false

  defp close_attach(handle, opts) do
    case close_attach_fun(opts).(handle, close_opts(opts)) |> normalize_sandbox_result() do
      :ok -> true
      {:error, _error} -> false
    end
  end

  defp close_session(session, opts) do
    case close_session_fun(opts).(session, close_opts(opts)) |> normalize_sandbox_result() do
      :ok -> true
      {:error, _error} -> false
    end
  end

  defp artifact_summaries(files, kind) do
    Enum.map(files, fn file ->
      content = IO.iodata_to_binary(file.content)

      %{
        path: file.path,
        kind: kind,
        bytes: byte_size(content),
        sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower),
        materialized_by: :sandbox_request_files
      }
    end)
  end

  defp materialized_files(source_files, test_files) do
    (source_files ++ test_files)
    |> Enum.map(fn file -> {file.path, file.content} end)
    |> Map.new()
  end

  defp attach_verification_summary(summary) do
    %{
      status: Map.get(summary, :status),
      exit_status: Map.get(summary, :exit_status),
      backend: Map.get(summary, :backend),
      terminal_count: Map.get(summary, :terminal_count),
      missing_terminal?: Map.get(summary, :missing_terminal?),
      synthetic_terminal?: Map.get(summary, :synthetic_terminal?),
      chunk_counts: Map.get(summary, :chunk_counts),
      byte_counts: Map.get(summary, :byte_counts),
      stdout: Map.get(summary, :stdout, ""),
      stderr: Map.get(summary, :stderr, ""),
      attach_id: Map.get(summary, :attach_id),
      session_id: Map.get(summary, :session_id)
    }
  end

  defp diagnostics(summary) do
    %{
      status: Map.get(summary, :status),
      exit_status: Map.get(summary, :exit_status),
      stdout_preview: Map.get(summary, :stdout, ""),
      stderr_preview: Map.get(summary, :stderr, ""),
      missing_terminal?: Map.get(summary, :missing_terminal?, false),
      backend: Map.get(summary, :backend)
    }
  end

  defp proof_metadata(metadata, summary, session) when is_map(metadata) do
    Map.merge(metadata, %{
      last_generated_component_proof: %{
        status: Map.get(summary, :status),
        attach_mode: Capabilities.attach_mode(session.capabilities),
        streaming_live?: Capabilities.streaming_live?(session.capabilities),
        backend: session.backend,
        isolation_level: session.isolation_level
      }
    })
  end

  defp session_summary(%Session{} = session) do
    %{
      id: session.id,
      sandbox: session.sandbox,
      backend: session.backend,
      isolation_level: session.isolation_level,
      state_model: session.state_model,
      transport_model: session.transport_model,
      persistent_identity?: session.persistent_identity?
    }
  end

  defp capability_summary(capabilities) do
    %{
      attach_mode: Capabilities.attach_mode(capabilities),
      attach_supported?: Capabilities.attach_supported?(capabilities),
      streaming_live?: Capabilities.streaming_live?(capabilities),
      terminal_result_adapter?: Capabilities.terminal_result_adapter?(capabilities),
      stdin_supported?: Capabilities.stdin_supported?(capabilities)
    }
  end

  defp verification_command(component, opts) do
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
     Error.validation("generated component proof #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: files}
     )}
  end

  defp file({path, content}, field), do: file(%{path: path, content: content}, field)

  defp file(file, field) when is_map(file) do
    path = Map.get(file, :path, Map.get(file, "path"))
    content = Map.get(file, :content, Map.get(file, "content"))

    with {:ok, path} <- required_string(path, "#{field}.path"),
         {:ok, content} <- required_binary(content, "#{field}.content") do
      {:ok, %{path: path, content: content}}
    end
  end

  defp file(file, field) do
    {:error,
     Error.validation("generated component proof #{field} entries must be maps or tuples",
       source: __MODULE__,
       details: %{field: field, value: file}
     )}
  end

  defp required_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}

  defp required_string(value, field) do
    {:error,
     Error.validation("generated component proof requires #{field}",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp required_binary(value, _field) when is_binary(value), do: {:ok, value}

  defp required_binary(value, field) do
    {:error,
     Error.validation("generated component proof requires #{field}",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_sandbox_result({:ok, value}), do: {:ok, value}
  defp normalize_sandbox_result(:ok), do: :ok
  defp normalize_sandbox_result({:error, error}), do: {:error, normalize_error(error)}

  defp normalize_error(%LitterBox.Error{} = error) do
    Error.new(error.kind, error.message,
      details: error.details,
      source: error.source,
      retryable?: error.retryable?,
      metadata: error.metadata
    )
  end

  defp normalize_error(%Error{} = error), do: error
  defp normalize_error(reason), do: Error.from_reason(reason, source: __MODULE__)

  defp open_session_fun(opts), do: Keyword.get(opts, :open_session, &LitterBox.open_session/3)
  defp attach_fun(opts), do: Keyword.get(opts, :attach, &LitterBox.attach/3)
  defp close_attach_fun(opts), do: Keyword.get(opts, :close_attach, &LitterBox.close_attach/2)

  defp close_session_fun(opts),
    do: Keyword.get(opts, :close_session, &LitterBox.close_session/2)

  defp attach_opts(opts), do: Keyword.get(opts, :attach_opts, [])
  defp close_opts(opts), do: Keyword.get(opts, :close_opts, [])

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value
end
