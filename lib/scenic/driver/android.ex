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

  defstruct [:socket, :socket_path, :viewport, :connected]

  @impl Scenic.Driver
  def validate_opts(opts), do: NimbleOptions.validate(Enum.into(opts, []), @opts_schema)

  @impl Scenic.Driver
  def init(driver, opts) do
    socket_path = opts[:socket_path] || @socket_path

    Logger.info("#{__MODULE__}: Initializing with socket #{socket_path}")

    state = %__MODULE__{
      socket: nil,
      socket_path: socket_path,
      viewport: driver.viewport,
      connected: false
    }

    # Try to connect
    state = try_connect(state)

    {:ok, state}
  end

  @impl Scenic.Driver
  def reset_scene(state) do
    Logger.debug("#{__MODULE__}: reset_scene")
    send_message(state, @msg_reset, <<>>)
    {:ok, state}
  end

  @impl Scenic.Driver
  def clear_color(color, state) do
    Logger.debug("#{__MODULE__}: clear_color #{inspect(color)}")

    {r, g, b, a} = normalize_color(color)
    payload = <<r::float-32, g::float-32, b::float-32, a::float-32>>

    send_message(state, @msg_clear_color, payload)
    {:ok, state}
  end

  @impl Scenic.Driver
  def update_scene(ids, state) do
    Logger.debug("#{__MODULE__}: update_scene #{inspect(ids)}")

    Enum.each(ids, fn id ->
      case ViewPort.get_script_by_id(state.viewport, id) do
        {:ok, script} ->
          serialized = Scenic.Script.serialize(script)
          # Send script ID (4 bytes) + serialized data
          payload = <<id::32>> <> serialized
          send_message(state, @msg_update_scene, payload)

        _ ->
          :ok
      end
    end)

    {:ok, state}
  end

  @impl Scenic.Driver
  def del_scripts(ids, state) do
    Logger.debug("#{__MODULE__}: del_scripts #{inspect(ids)}")

    payload = :erlang.term_to_binary(ids)
    send_message(state, @msg_delete_scripts, payload)

    {:ok, state}
  end

  @impl Scenic.Driver
  def request_input(_inputs, state) do
    # Input will come from Android side
    {:ok, state}
  end

  @impl Scenic.Driver
  def handle_info({:tcp, _socket, data}, state) do
    # Handle input events from Android
    handle_input(data, state)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("#{__MODULE__}: Socket closed, reconnecting...")
    state = %{state | socket: nil, connected: false}
    Process.send_after(self(), :reconnect, 1000)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    state = try_connect(state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__}: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp try_connect(state) do
    case :gen_tcp.connect({:local, state.socket_path}, 0, [:binary, active: true]) do
      {:ok, socket} ->
        Logger.info("#{__MODULE__}: Connected to Android host")
        %{state | socket: socket, connected: true}

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: Connection failed: #{inspect(reason)}, retrying in 1s")
        Process.send_after(self(), :reconnect, 1000)
        state
    end
  end

  defp send_message(%{socket: nil}, _type, _payload), do: :ok
  defp send_message(%{socket: socket}, type, payload) do
    # Message format: [type:1][length:4][payload:length]
    length = byte_size(payload)
    message = <<type::8, length::32>> <> payload
    :gen_tcp.send(socket, message)
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

  defp handle_touch_input(<<action::8, x::float-32, y::float-32>>, state) do
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

      Scenic.ViewPort.input(state.viewport, input)
    end
  end

  defp handle_key_input(_data, _state), do: :ok
end
