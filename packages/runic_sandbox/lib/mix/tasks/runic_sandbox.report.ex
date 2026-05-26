defmodule Mix.Tasks.RunicSandbox.Report do
  @moduledoc """
  Generate structured RunicSandbox validation reports.

      mix runic_sandbox.report
      mix runic_sandbox.report --format json
  """

  use Mix.Task

  @shortdoc "Generate RunicSandbox health, latency, and security reports"

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [format: :string])

    if invalid != [] do
      Mix.raise("invalid runic_sandbox.report options: #{inspect(invalid)}")
    end

    report = %{
      health_matrix: RunicSandbox.Reports.health_matrix(),
      latency_report: RunicSandbox.Reports.latency_report(),
      security_posture: RunicSandbox.Reports.security_posture()
    }

    case Keyword.get(opts, :format, "text") do
      "json" -> Mix.shell().info(Jason.encode!(json_safe(report), pretty: true))
      "text" -> print_text(report)
      other -> Mix.raise("unsupported report format: #{other}")
    end
  end

  defp print_text(report) do
    Mix.shell().info("Backend health")

    Enum.each(report.health_matrix.rows, fn row ->
      Mix.shell().info(
        "#{row.backend}: status=#{row.status} isolation=#{row.isolation_level} duration_us=#{row.duration_us}"
      )
    end)

    Mix.shell().info("\nLatency")

    Enum.each(report.latency_report.rows, fn row ->
      Mix.shell().info(
        "#{row.backend}: status_us=#{row.status.duration_us} provision_us=#{row.provision.duration_us} cold_exec_us=#{row.cold_exec.duration_us} warm_exec_us=#{row.warm_exec.duration_us} session_open_us=#{row.session_open.duration_us} session_exec_us=#{row.session_exec.duration_us} checkpoint_us=#{row.session_checkpoint.duration_us} restore_us=#{row.session_restore.duration_us} close_us=#{row.session_close.duration_us} snapshot_us=#{row.snapshot.duration_us} reset_us=#{row.reset.duration_us}"
      )
    end)

    Mix.shell().info("\nSecurity posture")

    Enum.each(report.security_posture.rows, fn row ->
      Mix.shell().info(
        "#{row.backend}: isolation=#{row.isolation_level} boundary=#{row.boundary}"
      )
    end)
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value
end
