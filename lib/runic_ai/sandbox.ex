defmodule RunicAI.Sandbox do
  @moduledoc """
  Backwards-compatible RunicAI sandbox facade.

  Stable sandbox contracts and backends live in the `RunicSandbox` package.
  RunicAI-specific tools, review gates, trace events, persistence, and
  Workbench UI should use the package facade directly for new code.
  """

  defdelegate child_spec(opts), to: RunicSandbox
  defdelegate start_link(opts), to: RunicSandbox
  defdelegate exec(request_or_session, opts_or_request \\ []), to: RunicSandbox
  defdelegate exec(session, request, opts), to: RunicSandbox
  defdelegate status(opts \\ []), to: RunicSandbox
  defdelegate provision(profile_input), to: RunicSandbox
  defdelegate exec_with_instance(instance, request, opts \\ []), to: RunicSandbox
  defdelegate snapshot(instance, opts \\ []), to: RunicSandbox
  defdelegate reset(instance, opts \\ []), to: RunicSandbox
  defdelegate destroy(instance, opts \\ []), to: RunicSandbox
  defdelegate open_session(sandbox, spec \\ [], opts \\ []), to: RunicSandbox
  defdelegate acquire_session(sandbox, spec \\ [], opts \\ []), to: RunicSandbox
  defdelegate release_session(session, opts \\ []), to: RunicSandbox
  defdelegate reset_session(session, opts \\ []), to: RunicSandbox
  defdelegate close_session(session, opts \\ []), to: RunicSandbox
  defdelegate write_file(session, path, contents, opts \\ []), to: RunicSandbox
  defdelegate read_file(session, path, opts \\ []), to: RunicSandbox
  defdelegate list_files(session, path \\ ".", opts \\ []), to: RunicSandbox
  defdelegate delete_file(session, path, opts \\ []), to: RunicSandbox
  defdelegate checkpoint(session, spec \\ [], opts \\ []), to: RunicSandbox
  defdelegate restore(session, checkpoint, opts \\ []), to: RunicSandbox
  defdelegate start_service(session, spec, opts \\ []), to: RunicSandbox
  defdelegate stop_service(session, service, opts \\ []), to: RunicSandbox
  defdelegate list_services(session, opts \\ []), to: RunicSandbox
  defdelegate open_proxy(session, service, opts \\ []), to: RunicSandbox
  defdelegate close_proxy(proxy, opts \\ []), to: RunicSandbox
  defdelegate acquire_lease(session, resource, opts \\ []), to: RunicSandbox
  defdelegate release_lease(lease, opts \\ []), to: RunicSandbox
end
