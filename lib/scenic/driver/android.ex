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
  alias Scenic.Assets.Static
  alias Scenic.Assets.Stream
  alias Scenic.Script

  @socket_path "/data/data/com.probnik/cache/scenic.sock"

  # Message types
  @msg_clear_color 1
  @msg_update_scene 2
  @msg_delete_scripts 3
  @msg_reset 4
  @msg_put_font 5
  @msg_put_image 6

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
        connected: false,
        media: %{fonts: [], images: [], streams: []}
      )

    # Try to connect
    driver = try_connect(driver)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def reset_scene(driver) do
    Logger.debug("#{__MODULE__}: reset_scene")
    send_message(driver, @msg_reset, <<>>)
    driver = Scenic.Driver.assign(driver, :media, %{fonts: [], images: [], streams: []})
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

    driver =
      Enum.reduce(ids, driver, fn id, driver ->
        case ViewPort.get_script(driver.viewport, id) do
          {:ok, script} ->
            driver = ensure_media(script, driver)
            script_bin = script |> Script.serialize() |> IO.iodata_to_binary()
            payload = encode_script(id, script_bin)
            Logger.info("#{__MODULE__}: script #{inspect(id)} bytes=#{byte_size(script_bin)}")
            send_message(driver, @msg_update_scene, payload)
            driver

          {:error, :not_found} ->
            driver
        end
      end)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def del_scripts(ids, driver) do
    Logger.debug("#{__MODULE__}: del_scripts #{inspect(ids)}")

    Enum.each(ids, fn id ->
      payload = encode_script_id(id)
      send_message(driver, @msg_delete_scripts, payload)
    end)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def request_input(_inputs, driver) do
    # Input will come from Android side
    {:ok, driver}
  end

  @impl true
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
      3 -> handle_resize_input(rest, state)
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

  defp handle_resize_input(<<w::float-32, h::float-32>>, driver) do
    Scenic.ViewPort.input(driver.viewport, {:viewport, {:reshape, {w, h}}})
  end

  defp ensure_media(script, driver) do
    media = Script.media(script)

    driver
    |> ensure_fonts(Map.get(media, :fonts, []))
    |> ensure_images(Map.get(media, :images, []))
    |> ensure_streams(Map.get(media, :streams, []))
  end

  defp ensure_fonts(driver, []), do: driver

  defp ensure_fonts(%{assigns: %{media: media}} = driver, ids) do
    fonts = Map.get(media, :fonts, [])

    fonts =
      Enum.reduce(ids, fonts, fn id, fonts ->
        with false <- Enum.member?(fonts, id),
             {:ok, {Static.Font, _}} <- Static.meta(id),
             {:ok, str_hash} <- Static.to_hash(id),
             {:ok, bin} <- Static.load(id) do
          send_message(driver, @msg_put_font, encode_font(str_hash, bin))
          [id | fonts]
        else
          _ -> fonts
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :fonts, fonts))
  end

  defp ensure_images(driver, []), do: driver

  defp ensure_images(%{assigns: %{media: media}} = driver, ids) do
    images = Map.get(media, :images, [])

    images =
      Enum.reduce(ids, images, fn id, images ->
        with false <- Enum.member?(images, id),
             {:ok, {Static.Image, {w, h, _}}} <- Static.meta(id),
             {:ok, str_hash} <- Static.to_hash(id),
             {:ok, bin} <- Static.load(id) do
          send_message(driver, @msg_put_image, encode_image(str_hash, :file, w, h, bin))
          [id | images]
        else
          _ -> images
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :images, images))
  end

  defp ensure_streams(driver, []), do: driver

  defp ensure_streams(%{assigns: %{media: media}} = driver, ids) do
    streams = Map.get(media, :streams, [])

    streams =
      Enum.reduce(ids, streams, fn id, streams ->
        with false <- Enum.member?(streams, id),
             :ok <- Stream.subscribe(id) do
          case Stream.fetch(id) do
            {:ok, {Stream.Image, {w, h, _format}, bin}} ->
              send_message(driver, @msg_put_image, encode_image(id, :file, w, h, bin))
              [id | streams]

            {:ok, {Stream.Bitmap, {w, h, format}, bin}} ->
              send_message(driver, @msg_put_image, encode_image(id, format, w, h, bin))
              [id | streams]

            _ ->
              streams
          end
        else
          _ -> streams
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :streams, streams))
  end

  defp encode_script(id, script_bin) do
    id_bin = encode_id(id)
    [<<byte_size(id_bin)::unsigned-integer-size(32)-native>>, id_bin, script_bin]
    |> IO.iodata_to_binary()
  end

  defp encode_script_id(id) do
    id_bin = encode_id(id)
    [<<byte_size(id_bin)::unsigned-integer-size(32)-native>>, id_bin]
    |> IO.iodata_to_binary()
  end

  defp encode_font(name, bin) do
    [
      <<byte_size(name)::unsigned-integer-size(32)-native>>,
      <<byte_size(bin)::unsigned-integer-size(32)-native>>,
      name,
      bin
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_image(id, format, w, h, bin) do
    format_id =
      case format do
        :file -> 0
        :g -> 1
        :ga -> 2
        :rgb -> 3
        :rgba -> 4
        _ -> 0
      end

    id_bin = encode_id(id)

    [
      <<
        byte_size(id_bin)::unsigned-integer-size(32)-native,
        byte_size(bin)::unsigned-integer-size(32)-native,
        w::unsigned-integer-size(32)-native,
        h::unsigned-integer-size(32)-native,
        format_id::unsigned-integer-size(32)-native
      >>,
      id_bin,
      bin
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_id(id) when is_binary(id), do: id
  defp encode_id(id) when is_atom(id), do: Atom.to_string(id)
  defp encode_id(id), do: to_string(id)
end
