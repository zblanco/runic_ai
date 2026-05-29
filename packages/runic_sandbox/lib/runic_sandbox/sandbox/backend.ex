defmodule RunicSandbox.Backend do
  @moduledoc """
  Behaviour implemented by sandbox backends.
  """

  alias RunicSandbox.Error
  alias RunicSandbox.AttachHandle
  alias RunicSandbox.ExecutionRequest
  alias RunicSandbox.ExecutionResult
  alias RunicSandbox.FileRef
  alias RunicSandbox.Instance
  alias RunicSandbox.Profile
  alias RunicSandbox.Session

  @callback provision(Profile.t(), keyword()) :: {:ok, Instance.t()} | {:error, Error.t()}
  @callback exec(Instance.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, ExecutionResult.t()} | {:error, Error.t()}
  @callback upload(Instance.t(), list(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  @callback download(Instance.t(), list(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  @callback snapshot(Instance.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  @callback reset(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback destroy(Instance.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback health(keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback open_session(Profile.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  @callback close_session(Session.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback exec_session(Session.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, ExecutionResult.t()} | {:error, Error.t()}
  @callback attach_session(Session.t(), ExecutionRequest.t(), keyword()) ::
              {:ok, AttachHandle.t()} | {:error, Error.t()}
  @callback write_stdin(AttachHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  @callback close_attach(AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback write_file(Session.t(), Path.t(), iodata(), keyword()) ::
              {:ok, FileRef.t()} | {:error, Error.t()}
  @callback read_file(Session.t(), Path.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  @callback list_files(Session.t(), Path.t(), keyword()) ::
              {:ok, [FileRef.t()]} | {:error, Error.t()}
  @callback delete_file(Session.t(), Path.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback checkpoint(Session.t(), keyword() | map(), keyword()) ::
              {:ok, RunicSandbox.Checkpoint.t()} | {:error, Error.t()}
  @callback restore(Session.t(), RunicSandbox.Checkpoint.t() | String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, Error.t()}
  @callback start_service(Session.t(), keyword() | map(), keyword()) ::
              {:ok, RunicSandbox.Service.t()} | {:error, Error.t()}
  @callback stop_service(Session.t(), RunicSandbox.Service.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback list_services(Session.t(), keyword()) ::
              {:ok, [RunicSandbox.Service.t()]} | {:error, Error.t()}
  @callback open_proxy(Session.t(), RunicSandbox.Service.t() | String.t(), keyword()) ::
              {:ok, RunicSandbox.Proxy.t()} | {:error, Error.t()}
  @callback close_proxy(RunicSandbox.Proxy.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}
  @callback acquire_lease(Session.t(), String.t(), keyword()) ::
              {:ok, RunicSandbox.Lease.t()} | {:error, Error.t()}
  @callback release_lease(RunicSandbox.Lease.t() | String.t(), keyword()) ::
              :ok | {:error, Error.t()}

  @optional_callbacks open_session: 2,
                      close_session: 2,
                      exec_session: 3,
                      attach_session: 3,
                      write_stdin: 3,
                      close_attach: 2,
                      write_file: 4,
                      read_file: 3,
                      list_files: 3,
                      delete_file: 3,
                      checkpoint: 3,
                      restore: 3,
                      start_service: 3,
                      stop_service: 3,
                      list_services: 2,
                      open_proxy: 3,
                      close_proxy: 2,
                      acquire_lease: 3,
                      release_lease: 2

  @spec open_session(module(), Profile.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def open_session(module, %Profile{} = profile, opts) do
    Code.ensure_loaded?(module)

    if function_exported?(module, :open_session, 2) do
      module.open_session(profile, opts)
    else
      with {:ok, instance} <- module.provision(profile, opts) do
        Session.from_instance(instance,
          capabilities: session_capabilities(profile),
          policy: profile.policy,
          metadata: %{compatibility_mode: :one_shot_session}
        )
      end
    end
  end

  @spec close_session(module(), Session.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_session(module, %Session{} = session, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :close_session, 2) ->
        module.close_session(session, opts)

      match?(%Instance{}, session.instance) ->
        module.destroy(session.instance, opts)

      true ->
        :ok
    end
  end

  @spec exec_session(module(), Session.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, ExecutionResult.t()} | {:error, Error.t()}
  def exec_session(module, %Session{} = session, %ExecutionRequest{} = request, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :exec_session, 3) ->
        module.exec_session(session, request, opts)

      match?(%Instance{}, session.instance) and session.capabilities.exec? ->
        module.exec(session.instance, request, opts)

      true ->
        unsupported(:exec_session, session)
    end
  end

  @spec attach_session(module(), Session.t(), ExecutionRequest.t(), keyword()) ::
          {:ok, AttachHandle.t()} | {:error, Error.t()}
  def attach_session(module, %Session{} = session, %ExecutionRequest{} = request, opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :attach_session, 3) ->
        module.attach_session(session, request, opts)

      true ->
        unsupported(:attach_session, session)
    end
  end

  @spec write_stdin(module(), AttachHandle.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def write_stdin(module, %AttachHandle{} = handle, input, opts) do
    dispatch_or_unsupported(module, :write_stdin, [handle, input, opts], handle)
  end

  @spec close_attach(module(), AttachHandle.t(), keyword()) :: :ok | {:error, Error.t()}
  def close_attach(module, %AttachHandle{} = handle, opts) do
    dispatch_or_unsupported(module, :close_attach, [handle, opts], handle)
  end

  def write_file(module, session, path, contents, opts),
    do: dispatch_or_unsupported(module, :write_file, [session, path, contents, opts], session)

  def read_file(module, session, path, opts),
    do: dispatch_or_unsupported(module, :read_file, [session, path, opts], session)

  def list_files(module, session, path, opts),
    do: dispatch_or_unsupported(module, :list_files, [session, path, opts], session)

  def delete_file(module, session, path, opts),
    do: dispatch_or_unsupported(module, :delete_file, [session, path, opts], session)

  def checkpoint(module, session, spec, opts),
    do: dispatch_or_unsupported(module, :checkpoint, [session, spec, opts], session)

  def restore(module, session, checkpoint, opts),
    do: dispatch_or_unsupported(module, :restore, [session, checkpoint, opts], session)

  def start_service(module, session, spec, opts),
    do: dispatch_or_unsupported(module, :start_service, [session, spec, opts], session)

  def stop_service(module, session, service, opts),
    do: dispatch_or_unsupported(module, :stop_service, [session, service, opts], session)

  def list_services(module, session, opts),
    do: dispatch_or_unsupported(module, :list_services, [session, opts], session)

  def open_proxy(module, session, service, opts),
    do: dispatch_or_unsupported(module, :open_proxy, [session, service, opts], session)

  def close_proxy(module, proxy, opts),
    do: dispatch_or_unsupported(module, :close_proxy, [proxy, opts], proxy)

  def acquire_lease(module, session, resource, opts),
    do: dispatch_or_unsupported(module, :acquire_lease, [session, resource, opts], session)

  def release_lease(module, lease, opts),
    do: dispatch_or_unsupported(module, :release_lease, [lease, opts], lease)

  @spec unsupported(atom(), term()) :: {:error, Error.t()}
  def unsupported(operation, subject) do
    {backend, session_id} =
      case subject do
        %Session{} = session -> {session.backend, session.id}
        %{backend: backend} -> {backend, nil}
        _other -> {:unknown, nil}
      end

    {:error,
     Error.validation("sandbox backend does not support #{operation}",
       source: __MODULE__,
       details: %{operation: operation, backend: backend, session_id: session_id}
     )}
  end

  defp dispatch_or_unsupported(module, operation, args, subject) do
    Code.ensure_loaded?(module)

    if function_exported?(module, operation, length(args)) do
      apply(module, operation, args)
    else
      unsupported(operation, subject)
    end
  end

  defp session_capabilities(%Profile{} = profile) do
    RunicSandbox.Capabilities.one_shot_exec(
      network_policy?: true,
      persistent_identity?: profile.stateful? or profile.workspace.persist?
    )
  end
end
