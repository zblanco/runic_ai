defmodule RunicAI.Sandbox do
  @moduledoc """
  Backwards-compatible RunicAI sandbox facade.

  Stable sandbox contracts and backends live in the `LitterBox` package.
  RunicAI-specific tools, review gates, trace events, persistence, and
  Workbench UI should use the package facade directly for new code.
  """

  defdelegate child_spec(opts), to: LitterBox
  defdelegate start_link(opts), to: LitterBox
  defdelegate exec(request_or_session, opts_or_request \\ []), to: LitterBox
  defdelegate exec(session, request, opts), to: LitterBox
  defdelegate status(opts \\ []), to: LitterBox
  defdelegate provision(profile_input), to: LitterBox
  defdelegate exec_with_instance(instance, request, opts \\ []), to: LitterBox
  defdelegate snapshot(instance, opts \\ []), to: LitterBox
  defdelegate reset(instance, opts \\ []), to: LitterBox
  defdelegate destroy(instance, opts \\ []), to: LitterBox
  defdelegate open_session(sandbox, spec \\ [], opts \\ []), to: LitterBox
  defdelegate acquire_session(sandbox, spec \\ [], opts \\ []), to: LitterBox
  defdelegate release_session(session, opts \\ []), to: LitterBox
  defdelegate reset_session(session, opts \\ []), to: LitterBox
  defdelegate close_session(session, opts \\ []), to: LitterBox
  defdelegate write_file(session, path, contents, opts \\ []), to: LitterBox
  defdelegate read_file(session, path, opts \\ []), to: LitterBox
  defdelegate list_files(session, path \\ ".", opts \\ []), to: LitterBox
  defdelegate delete_file(session, path, opts \\ []), to: LitterBox
  defdelegate checkpoint(session, spec \\ [], opts \\ []), to: LitterBox
  defdelegate restore(session, checkpoint, opts \\ []), to: LitterBox
  defdelegate start_service(session, spec, opts \\ []), to: LitterBox
  defdelegate stop_service(session, service, opts \\ []), to: LitterBox
  defdelegate list_services(session, opts \\ []), to: LitterBox
  defdelegate open_proxy(session, service, opts \\ []), to: LitterBox
  defdelegate close_proxy(proxy, opts \\ []), to: LitterBox
  defdelegate acquire_lease(session, resource, opts \\ []), to: LitterBox
  defdelegate release_lease(lease, opts \\ []), to: LitterBox
end
