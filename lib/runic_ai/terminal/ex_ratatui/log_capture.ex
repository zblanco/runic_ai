defmodule RunicAI.Terminal.ExRatatui.LogCapture do
  @moduledoc """
  Logger handler used while the ExRatatui screen owns the terminal.

  Logger's default console handler writes directly to stdio, which corrupts the
  ratatui alternate screen. This handler mirrors log lines into the TUI process
  and temporarily raises the default console handler level while at least one
  TUI is attached.
  """

  @handler_id :runic_ai_ex_ratatui_log_capture
  @subscribers_key {__MODULE__, :subscribers}
  @console_level_key {__MODULE__, :default_console_level}
  @max_message_bytes 1_000

  @spec attach(pid()) :: :ok
  def attach(owner) when is_pid(owner) do
    ensure_handler()
    put_subscribers(Map.put(subscribers(), owner, true))
    silence_console()
    :ok
  end

  @spec detach(pid()) :: :ok
  def detach(owner) when is_pid(owner) do
    subscribers = Map.delete(subscribers(), owner)

    if map_size(subscribers) == 0 do
      clear_subscribers()
      restore_console()
      remove_handler()
    else
      put_subscribers(subscribers)
    end

    :ok
  end

  @spec log(map(), map()) :: :ok
  def log(event, _config) when is_map(event) do
    log = event_to_log(event)

    subscribers()
    |> Map.keys()
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: send(pid, {:runic_ai_tui_log, log})
    end)

    :ok
  rescue
    _exception -> :ok
  end

  def log(_event, _config), do: :ok

  defp ensure_handler do
    case :logger.get_handler_config(@handler_id) do
      {:ok, _config} ->
        :ok

      {:error, _reason} ->
        case :logger.add_handler(@handler_id, __MODULE__, %{level: :all, config: %{}}) do
          :ok -> :ok
          {:error, {:already_exist, _id}} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  defp remove_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp silence_console do
    if :persistent_term.get(@console_level_key, :unset) == :unset do
      case :logger.get_handler_config(:default) do
        {:ok, %{level: level}} ->
          :persistent_term.put(@console_level_key, level)
          _ = :logger.set_handler_config(:default, :level, :emergency)
          :ok

        _other ->
          :ok
      end
    end
  end

  defp restore_console do
    case :persistent_term.get(@console_level_key, :unset) do
      :unset ->
        :ok

      level ->
        _ = :logger.set_handler_config(:default, :level, level)
        :persistent_term.erase(@console_level_key)
        :ok
    end
  end

  defp event_to_log(%{level: level, msg: msg, meta: meta}) do
    %{
      id: "log:#{System.unique_integer([:positive])}",
      at: log_time(meta),
      level: level,
      message: msg_text(msg),
      source: source(meta)
    }
  end

  defp event_to_log(event) do
    %{
      id: "log:#{System.unique_integer([:positive])}",
      at: current_time(),
      level: :info,
      message: truncate(inspect(event, limit: 20, printable_limit: @max_message_bytes)),
      source: nil
    }
  end

  defp log_time(%{time: time}) when is_integer(time) do
    time
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_time()
    |> Time.truncate(:millisecond)
    |> Time.to_iso8601()
  rescue
    _exception -> current_time()
  end

  defp log_time(_meta), do: current_time()

  defp current_time do
    Time.utc_now()
    |> Time.truncate(:millisecond)
    |> Time.to_iso8601()
  end

  defp msg_text({:string, value}), do: chardata(value)

  defp msg_text({:report, report}),
    do: report |> inspect(limit: 20, printable_limit: @max_message_bytes) |> truncate()

  defp msg_text({:format, format, args}) do
    format
    |> :io_lib.format(List.wrap(args))
    |> chardata()
  rescue
    _exception -> inspect({format, args}, printable_limit: @max_message_bytes)
  end

  defp msg_text(value) when is_binary(value), do: truncate(value)

  defp msg_text(value),
    do: value |> inspect(limit: 20, printable_limit: @max_message_bytes) |> truncate()

  defp chardata(value) do
    value
    |> IO.chardata_to_string()
    |> truncate()
  rescue
    _exception -> inspect(value, printable_limit: @max_message_bytes)
  end

  defp source(%{mfa: {module, function, arity}}),
    do: "#{inspect(module)}.#{function}/#{arity}"

  defp source(%{module: module}) when not is_nil(module), do: inspect(module)
  defp source(_meta), do: nil

  defp truncate(message) when byte_size(message) <= @max_message_bytes, do: message
  defp truncate(message), do: String.slice(message, 0, @max_message_bytes - 3) <> "..."

  defp subscribers, do: :persistent_term.get(@subscribers_key, %{})
  defp put_subscribers(subscribers), do: :persistent_term.put(@subscribers_key, subscribers)
  defp clear_subscribers, do: :persistent_term.erase(@subscribers_key)
end
