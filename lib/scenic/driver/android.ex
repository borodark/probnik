defmodule Scenic.Driver.Android do
  @moduledoc """
  Scenic driver for Android.

  This is a thin wrapper around `ScenicDriverRemote` configured to use
  a Unix domain socket for communication with the Android native renderer.

  ## Configuration

      config :probnik, :viewport,
        size: {800, 600},
        drivers: [
          [module: Scenic.Driver.Android]
        ]

  ## Options

  - `:socket_path` - Path to the Unix socket (default: `/data/data/com.probnik/cache/scenic.sock`)
  """

  use Scenic.Driver
  require Logger

  @default_socket_path "/data/data/com.probnik/cache/scenic.sock"

  @opts_schema [
    name: [type: {:or, [:atom, :string]}],
    socket_path: [type: :string, default: @default_socket_path]
  ]

  @impl Scenic.Driver
  def validate_opts(opts), do: NimbleOptions.validate(Enum.into(opts, []), @opts_schema)

  @impl Scenic.Driver
  def init(driver, opts) do
    socket_path = opts[:socket_path] || @default_socket_path

    Logger.info("#{__MODULE__}: Initializing with socket #{socket_path}")

    # Delegate to ScenicDriverRemote with Unix socket transport
    remote_opts = [
      transport: ScenicDriverRemote.Transport.UnixSocket,
      path: socket_path,
      reconnect_interval: 1000
    ]

    # Initialize parent driver state
    driver =
      Scenic.Driver.assign(driver,
        remote_opts: remote_opts,
        transport_module: ScenicDriverRemote.Transport.UnixSocket,
        transport: nil,
        transport_opts: remote_opts,
        connected: false,
        reconnect_interval: 1000,
        media: %{fonts: [], images: [], streams: []},
        recv_buffer: <<>>
      )

    # Try to connect
    driver = try_connect(driver)

    {:ok, driver}
  end

  # Delegate all driver callbacks to the shared implementation

  @impl Scenic.Driver
  def reset_scene(driver) do
    Logger.debug("#{__MODULE__}: reset_scene")
    send_command(driver, ScenicDriverRemote.Protocol.Commands.reset())
    driver = Scenic.Driver.assign(driver, :media, %{fonts: [], images: [], streams: []})
    {:ok, driver}
  end

  @impl Scenic.Driver
  def clear_color(color, driver) do
    Logger.debug("#{__MODULE__}: clear_color #{inspect(color)}")
    {r, g, b, a} = normalize_color(color)
    send_command(driver, ScenicDriverRemote.Protocol.Commands.clear_color(r, g, b, a))
    {:ok, driver}
  end

  @impl Scenic.Driver
  def update_scene(ids, driver) do
    Logger.debug("#{__MODULE__}: update_scene #{inspect(ids)}")

    driver =
      Enum.reduce(ids, driver, fn id, driver ->
        case Scenic.ViewPort.get_script(driver.viewport, id) do
          {:ok, script} ->
            driver = ensure_media(script, driver)
            script_bin = script |> Scenic.Script.serialize() |> IO.iodata_to_binary()
            send_command(driver, ScenicDriverRemote.Protocol.Commands.put_script(id, script_bin))
            driver

          {:error, :not_found} ->
            driver
        end
      end)

    # Trigger render
    send_command(driver, ScenicDriverRemote.Protocol.Commands.render())

    {:ok, driver}
  end

  @impl Scenic.Driver
  def del_scripts(ids, driver) do
    Logger.debug("#{__MODULE__}: del_scripts #{inspect(ids)}")

    Enum.each(ids, fn id ->
      send_command(driver, ScenicDriverRemote.Protocol.Commands.del_script(id))
    end)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def request_input(_inputs, driver) do
    {:ok, driver}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, driver) do
    driver = handle_incoming_data(data, driver)
    {:noreply, driver}
  end

  def handle_info({:tcp_closed, _socket}, driver) do
    Logger.warning("#{__MODULE__}: Connection closed, reconnecting...")
    driver = Scenic.Driver.assign(driver, transport: nil, connected: false)
    reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
    Process.send_after(self(), :reconnect, reconnect_interval)
    {:noreply, driver}
  end

  def handle_info({:tcp_error, _socket, reason}, driver) do
    Logger.warning("#{__MODULE__}: Connection error: #{inspect(reason)}, reconnecting...")
    driver = Scenic.Driver.assign(driver, transport: nil, connected: false)
    reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
    Process.send_after(self(), :reconnect, reconnect_interval)
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
    transport_module = Scenic.Driver.get(driver, :transport_module)
    transport_opts = Scenic.Driver.get(driver, :transport_opts)

    case transport_module.connect(transport_opts) do
      {:ok, transport} ->
        Logger.info("#{__MODULE__}: Connected to Android host")
        Scenic.Driver.assign(driver, transport: transport, connected: true)

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: Connection failed: #{inspect(reason)}, retrying...")
        reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
        Process.send_after(self(), :reconnect, reconnect_interval)
        driver
    end
  end

  defp send_command(driver, command) do
    transport = Scenic.Driver.get(driver, :transport)
    transport_module = Scenic.Driver.get(driver, :transport_module)

    if transport && transport_module.connected?(transport) do
      transport_module.send(transport, command)
    else
      :ok
    end
  end

  defp handle_incoming_data(data, driver) do
    buffer = Scenic.Driver.get(driver, :recv_buffer) <> data
    {events, remaining} = ScenicDriverRemote.Protocol.Events.parse_all(buffer)

    Enum.each(events, fn event ->
      handle_event(event, driver)
    end)

    Scenic.Driver.assign(driver, :recv_buffer, remaining)
  end

  defp handle_event({:ready}, _driver) do
    Logger.info("#{__MODULE__}: Renderer ready")
    :ok
  end

  defp handle_event({:reshape, width, height}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:viewport, {:reshape, {width, height}}})
  end

  defp handle_event({:touch, action, x, y}, driver) do
    input =
      case action do
        :down -> {:cursor_button, {:btn_left, 1, [], {x, y}}}
        :up -> {:cursor_button, {:btn_left, 0, [], {x, y}}}
        :move -> {:cursor_pos, {x, y}}
      end

    Scenic.ViewPort.input(driver.viewport, input)
  end

  defp handle_event({:key, key, scancode, action, mods}, driver) do
    action_atom =
      case action do
        0 -> :release
        1 -> :press
        2 -> :repeat
        _ -> :press
      end

    Scenic.ViewPort.input(driver.viewport, {:key, {key, scancode, action_atom, mods}})
  end

  defp handle_event({:codepoint, codepoint, mods}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:codepoint, {codepoint, mods}})
  end

  defp handle_event({:cursor_pos, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:cursor_pos, {x, y}})
  end

  defp handle_event({:mouse_button, button, action, mods, x, y}, driver) do
    action_val = if action == 1, do: 1, else: 0
    Scenic.ViewPort.input(driver.viewport, {:cursor_button, {button, action_val, mods, {x, y}}})
  end

  defp handle_event({:scroll, x_offset, y_offset, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:scroll, {{x_offset, y_offset}, {x, y}}})
  end

  defp handle_event(_event, _driver), do: :ok

  defp normalize_color({r, g, b}) when is_integer(r), do: {r / 255, g / 255, b / 255, 1.0}
  defp normalize_color({r, g, b, a}) when is_integer(r), do: {r / 255, g / 255, b / 255, a / 255}
  defp normalize_color({r, g, b}) when is_float(r), do: {r, g, b, 1.0}
  defp normalize_color({r, g, b, a}) when is_float(r), do: {r, g, b, a}
  defp normalize_color(_), do: {0.0, 0.0, 0.0, 1.0}

  defp ensure_media(script, driver) do
    media = Scenic.Script.media(script)

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
             {:ok, {Scenic.Assets.Static.Font, _}} <- Scenic.Assets.Static.meta(id),
             {:ok, str_hash} <- Scenic.Assets.Static.to_hash(id),
             {:ok, bin} <- Scenic.Assets.Static.load(id) do
          send_command(driver, ScenicDriverRemote.Protocol.Commands.put_font(str_hash, bin))
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
             {:ok, {Scenic.Assets.Static.Image, {w, h, _}}} <- Scenic.Assets.Static.meta(id),
             {:ok, str_hash} <- Scenic.Assets.Static.to_hash(id),
             {:ok, bin} <- Scenic.Assets.Static.load(id) do
          send_command(driver, ScenicDriverRemote.Protocol.Commands.put_image(str_hash, :encoded, w, h, bin))
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
             :ok <- Scenic.Assets.Stream.subscribe(id) do
          case Scenic.Assets.Stream.fetch(id) do
            {:ok, {Scenic.Assets.Stream.Image, {w, h, _format}, bin}} ->
              send_command(driver, ScenicDriverRemote.Protocol.Commands.put_image(id, :encoded, w, h, bin))
              [id | streams]

            {:ok, {Scenic.Assets.Stream.Bitmap, {w, h, format}, bin}} ->
              send_command(driver, ScenicDriverRemote.Protocol.Commands.put_image(id, format, w, h, bin))
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
end
