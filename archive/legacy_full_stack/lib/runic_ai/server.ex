defmodule RunicAI.Server do
  @moduledoc """
  Local server entrypoint shared by escripts, releases, and Mix.

  The server command configures the Phoenix endpoint, the workbench SQLite
  store, and the local access token before starting the application.
  """

  require Logger

  @switches [
    port: :integer,
    ip: :string,
    data_path: :string,
    database: :string,
    token: :string,
    open_browser: :boolean,
    no_open: :boolean,
    log_level: :string,
    help: :boolean
  ]

  @default_port 4000
  @default_ip "127.0.0.1"
  @token_file "local_auth_token"
  @secret_file "secret_key_base"
  @log_levels %{
    "debug" => :debug,
    "info" => :info,
    "notice" => :notice,
    "warning" => :warning,
    "error" => :error
  }

  @type options :: %{
          port: pos_integer(),
          ip: String.t(),
          ip_tuple: tuple(),
          data_path: String.t(),
          database: String.t(),
          token: String.t() | nil,
          open_browser?: boolean(),
          log_level: Logger.level() | nil
        }

  @spec main([String.t()]) :: :ok | no_return()
  def main(args), do: run(args)

  @spec run([String.t()], keyword()) :: :ok | {:ok, options()} | no_return()
  def run(args, opts \\ [])

  def run(["server" | args], opts), do: serve(args, opts)

  def run(["help"], _opts), do: output_usage(&IO.puts/1)
  def run(["--help"], _opts), do: output_usage(&IO.puts/1)
  def run([], opts), do: serve([], opts)

  def run(args, _opts) do
    IO.puts(:stderr, "unknown command: #{Enum.join(args, " ")}\n")
    output_usage(&IO.puts/1)
    System.halt(64)
  end

  @spec serve([String.t()], keyword()) :: :ok | {:ok, options()} | no_return()
  def serve(args, opts \\ []) do
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)

    case parse(args) do
      {:ok, server_opts} ->
        {:ok, configured} = configure(server_opts)

        case Application.ensure_all_started(:runic_ai) do
          {:ok, _apps} ->
            url = tokenized_url(configured)
            output_fun.("RunicAI workbench listening on #{base_url(configured)}")
            output_fun.("Open #{url}")
            maybe_open_browser(configured, url, output_fun)

            if Keyword.get(opts, :block?, true) do
              Process.sleep(:infinity)
            else
              {:ok, configured}
            end

          {:error, reason} ->
            raise "could not start RunicAI server: #{inspect(reason)}"
        end

      {:help, usage} ->
        output_fun.(usage)
        :ok

      {:error, reason} ->
        output_fun.("runic_ai server error: #{reason}")
        output_fun.(usage())
        System.halt(64)
    end
  end

  @spec parse([String.t()]) :: {:ok, options()} | {:help, String.t()} | {:error, String.t()}
  def parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts = Map.new(opts)

        cond do
          Map.get(opts, :help) ->
            {:help, usage()}

          true ->
            build_options(opts)
        end

      {_opts, argv, []} ->
        {:error, "unexpected arguments: #{Enum.join(argv, " ")}"}

      {_opts, _argv, invalid} ->
        {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  @spec configure(options()) :: {:ok, options()} | {:error, term()}
  def configure(%{} = opts) do
    with :ok <- File.mkdir_p(opts.data_path),
         {:ok, token} <- token(opts),
         {:ok, secret_key_base} <- secret_key_base(opts.data_path) do
      opts = %{opts | token: token}
      configure_logger(opts)
      configure_workbench(opts)
      configure_endpoint(opts, secret_key_base)
      {:ok, opts}
    end
  end

  @spec tokenized_url(options()) :: String.t()
  def tokenized_url(%{token: token} = opts) when is_binary(token) do
    base_url(opts) <> "/?" <> URI.encode_query(%{"token" => token})
  end

  def tokenized_url(opts), do: base_url(opts) <> "/"

  @spec base_url(options()) :: String.t()
  def base_url(opts), do: "http://#{url_host(opts.ip)}:#{opts.port}"

  @spec usage() :: String.t()
  def usage do
    """
    Usage:
      runic_ai server [options]
      mix runic_ai.server [options]

    Options:
      --port N              Bind port. Defaults to 4000.
      --ip IP               Bind address. Defaults to 127.0.0.1.
      --data-path PATH      Local data directory. Defaults to ~/.runic_ai.
      --database PATH       SQLite database path. Defaults to DATA_PATH/runs.db.
      --token TOKEN         Local access token. Defaults to DATA_PATH/local_auth_token.
      --open-browser        Open the tokenized URL after startup.
      --no-open             Do not open a browser.
      --log-level LEVEL     debug, info, notice, warning, or error.
      --help                Show this help.
    """
  end

  defp build_options(opts) do
    data_path =
      opts
      |> Map.get(:data_path, default_data_path())
      |> Path.expand()

    database =
      opts
      |> Map.get(:database, Path.join(data_path, "runs.db"))
      |> Path.expand()

    ip = Map.get(opts, :ip, @default_ip)

    with {:ok, port} <- port(Map.get(opts, :port, @default_port)),
         {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, log_level} <- log_level(Map.get(opts, :log_level)) do
      {:ok,
       %{
         port: port,
         ip: ip,
         ip_tuple: ip_tuple,
         data_path: data_path,
         database: database,
         token: blank_to_nil(Map.get(opts, :token)),
         open_browser?:
           Map.get(opts, :open_browser, false) and not Map.get(opts, :no_open, false),
         log_level: log_level
       }}
    end
  end

  defp default_data_path do
    System.get_env("RUNIC_AI_DATA_PATH") || Path.join(System.user_home!(), ".runic_ai")
  end

  defp port(port) when is_integer(port) and port > 0 and port < 65_536, do: {:ok, port}
  defp port(_port), do: {:error, "--port must be between 1 and 65535"}

  defp parse_ip(ip) when is_binary(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _reason} -> {:error, "--ip must be a valid IPv4 or IPv6 address"}
    end
  end

  defp log_level(nil), do: {:ok, nil}

  defp log_level(value) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()

    case Map.fetch(@log_levels, normalized) do
      {:ok, level} -> {:ok, level}
      :error -> {:error, "--log-level must be debug, info, notice, warning, or error"}
    end
  end

  defp token(%{token: token}) when is_binary(token), do: {:ok, token}

  defp token(%{data_path: data_path}) do
    secret_path = Path.join(data_path, @token_file)

    case File.read(secret_path) do
      {:ok, token} ->
        {:ok, String.trim(token)}

      {:error, :enoent} ->
        token = random_secret(32)

        with :ok <- File.write(secret_path, token <> "\n"),
             :ok <- chmod_private(secret_path) do
          {:ok, token}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp secret_key_base(data_path) do
    secret_path = Path.join(data_path, @secret_file)

    cond do
      value = System.get_env("RUNIC_AI_SECRET_KEY_BASE") ->
        {:ok, value}

      value = System.get_env("SECRET_KEY_BASE") ->
        {:ok, value}

      true ->
        case File.read(secret_path) do
          {:ok, secret} ->
            {:ok, String.trim(secret)}

          {:error, :enoent} ->
            secret = random_secret(64)

            with :ok <- File.write(secret_path, secret <> "\n"),
                 :ok <- chmod_private(secret_path) do
              {:ok, secret}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp random_secret(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp chmod_private(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp configure_logger(%{log_level: nil}), do: :ok
  defp configure_logger(%{log_level: level}), do: Logger.configure(level: level)

  defp configure_workbench(opts) do
    config =
      :runic_ai
      |> Application.get_env(:workbench, [])
      |> Keyword.merge(
        data_path: opts.data_path,
        database: opts.database,
        migrate?: true,
        auth_token: opts.token,
        auth_required?: true,
        bind_ip: opts.ip,
        bind_port: opts.port
      )

    Application.put_env(:runic_ai, :workbench, config)
  end

  defp configure_endpoint(opts, secret_key_base) do
    endpoint =
      :runic_ai
      |> Application.get_env(RunicAIWeb.Endpoint, [])
      |> Keyword.put(:server, true)
      |> Keyword.put(:code_reloader, false)
      |> Keyword.put(:watchers, [])
      |> Keyword.put(:http, ip: opts.ip_tuple, port: opts.port)
      |> Keyword.put(:url, host: url_host(opts.ip), port: opts.port, scheme: "http")
      |> Keyword.put(:secret_key_base, secret_key_base)

    Application.put_env(:runic_ai, RunicAIWeb.Endpoint, endpoint)
  end

  defp maybe_open_browser(%{open_browser?: false}, _url, _output_fun), do: :ok

  defp maybe_open_browser(%{open_browser?: true}, url, output_fun) do
    case browser_command() do
      nil ->
        output_fun.("No browser opener found; open the URL manually.")

      {command, args} ->
        case System.cmd(command, args ++ [url], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> output_fun.("Browser opener failed: #{String.trim(output)}")
        end
    end
  end

  defp browser_command do
    cond do
      System.find_executable("xdg-open") -> {"xdg-open", []}
      System.find_executable("open") -> {"open", []}
      System.find_executable("cmd") -> {"cmd", ["/c", "start"]}
      true -> nil
    end
  end

  defp url_host("127.0.0.1"), do: "localhost"
  defp url_host("::1"), do: "localhost"
  defp url_host("0.0.0.0"), do: "127.0.0.1"
  defp url_host("::"), do: "127.0.0.1"
  defp url_host(ip), do: ip

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp output_usage(output_fun) do
    output_fun.(usage())
    :ok
  end
end
