defmodule Scenic.Driver.Android do
  @moduledoc """
  Scenic driver for Android.

  Communicates with the Android host via a Unix domain socket.
  The Android native code receives serialized render commands and
  executes OpenGL ES calls.
  """

  use Scenic.Driver
  require Logger

  alias Scenic.ViewPort

  @socket_path "/data/data/com.probnik/cache/scenic.sock"

  # Message types
  @msg_clear_color 1
  @msg_update_scene 2
  @msg_delete_scripts 3
  @msg_reset 4

  @opts_schema [
    name: [type: {:or, [:atom, :string]}],
    socket_path: [type: :string, default: @socket_path]
  ]

  @impl Scenic.Driver
  def validate_opts(opts), do: NimbleOptions.validate(Enum.into(opts, []), @opts_schema)

  @impl Scenic.Driver
  def init(driver, opts) do
    socket_path = opts[:socket_path] || @socket_path

    Logger.info("#{__MODULE__}: Initializing with socket #{socket_path}")
    IO.puts("#{__MODULE__}: init socket_path=#{socket_path}")

    driver =
      Scenic.Driver.assign(driver,
        socket: nil,
        socket_path: socket_path,
        connected: false
      )

    # Try to connect
    driver = try_connect(driver)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def reset_scene(driver) do
    Logger.debug("#{__MODULE__}: reset_scene")
    send_message(driver, @msg_reset, <<>>)
    {:ok, driver}
  end

  @impl Scenic.Driver
  def clear_color(color, driver) do
    Logger.debug("#{__MODULE__}: clear_color #{inspect(color)}")

    {r, g, b, a} = normalize_color(color)
    payload = <<r::float-32, g::float-32, b::float-32, a::float-32>>

    send_message(driver, @msg_clear_color, payload)
    {:ok, driver}
  end

  @impl Scenic.Driver
  def update_scene(ids, driver) do
    Logger.debug("#{__MODULE__}: update_scene #{inspect(ids)}")

    Enum.each(ids, fn id ->
      case ViewPort.get_script(driver.viewport, id) do
        {:ok, script} ->
          serialized = script |> Scenic.Script.serialize() |> IO.iodata_to_binary()
          # Native side ignores script id for now; send serialized script only
          send_message(driver, @msg_update_scene, serialized)

        {:error, :not_found} ->
          :ok
      end
    end)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def del_scripts(ids, driver) do
    Logger.debug("#{__MODULE__}: del_scripts #{inspect(ids)}")

    payload = :erlang.term_to_binary(ids)
    send_message(driver, @msg_delete_scripts, payload)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def request_input(_inputs, driver) do
    # Input will come from Android side
    {:ok, driver}
  end

  @impl Scenic.Driver
  def handle_info({:tcp, _socket, data}, driver) do
    # Handle input events from Android
    handle_input(data, driver)
    {:noreply, driver}
  end

  def handle_info({:tcp_closed, _socket}, driver) do
    Logger.warning("#{__MODULE__}: Socket closed, reconnecting...")
    driver = Scenic.Driver.assign(driver, socket: nil, connected: false)
    Process.send_after(self(), :reconnect, 1000)
    {:noreply, driver}
  end

  def handle_info(:reconnect, driver) do
    driver = try_connect(driver)
    {:noreply, driver}
  end

  def handle_info(msg, driver) do
    Logger.debug("#{__MODULE__}: Unhandled message: #{inspect(msg)}")
    {:noreply, driver}
  end

  # Private functions

  defp try_connect(driver) do
    socket_path = Scenic.Driver.get(driver, :socket_path)

    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: true]) do
      {:ok, socket} ->
        Logger.info("#{__MODULE__}: Connected to Android host")
        IO.puts("#{__MODULE__}: connected")
        Scenic.Driver.assign(driver, socket: socket, connected: true)

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: Connection failed: #{inspect(reason)}, retrying in 1s")
        IO.puts("#{__MODULE__}: connect failed #{inspect(reason)}")
        Process.send_after(self(), :reconnect, 1000)
        driver
    end
  end

  defp send_message(driver, _type, _payload) when is_nil(driver), do: :ok
  defp send_message(driver, type, payload) do
    socket = Scenic.Driver.get(driver, :socket)
    if is_nil(socket) do
      :ok
    else
    # Message format: [type:1][length:4][payload:length]
    length = byte_size(payload)
    message = <<type::8, length::32>> <> payload
    :gen_tcp.send(socket, message)
    end
  end

  defp normalize_color({r, g, b}) when is_integer(r), do: {r / 255, g / 255, b / 255, 1.0}
  defp normalize_color({r, g, b, a}) when is_integer(r), do: {r / 255, g / 255, b / 255, a / 255}
  defp normalize_color({r, g, b}) when is_float(r), do: {r, g, b, 1.0}
  defp normalize_color({r, g, b, a}) when is_float(r), do: {r, g, b, a}
  defp normalize_color(_), do: {0.0, 0.0, 0.0, 1.0}

  defp handle_input(<<type::8, rest::binary>>, state) do
    case type do
      1 -> handle_touch_input(rest, state)
      2 -> handle_key_input(rest, state)
      _ -> :ok
    end
  end

  defp handle_touch_input(<<action::8, x::float-32, y::float-32>>, driver) do
    input_type = case action do
      0 -> :cursor_button  # down
      1 -> :cursor_button  # up
      2 -> :cursor_pos     # move
      _ -> nil
    end

    if input_type do
      input = case action do
        0 -> {:cursor_button, {:btn_left, 1, [], {x, y}}}
        1 -> {:cursor_button, {:btn_left, 0, [], {x, y}}}
        2 -> {:cursor_pos, {x, y}}
      end

      Scenic.ViewPort.input(driver.viewport, input)
    end
  end

  defp handle_key_input(_data, _state), do: :ok
end
