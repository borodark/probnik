defmodule Probnik.Scene.Startup do
  use Scenic.Scene

  require Logger

  alias Scenic.Graph
  import Scenic.Primitives
  alias Scenic.Components

  alias Probnik.ColorScheme

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    c = ColorScheme.current()
    {vw, vh} = scene.viewport.size

    state = %{
      mode: :remote,
      token: "secret_token",
      remote_host: Application.get_env(:probnik, :remote_host, "super-io"),
      remote_node: Application.get_env(:probnik, :remote_node, :"one@super-io"),
      viewport: {vw, vh}
    }

    graph =
      Graph.build(font: :courier, font_size: 28)
      |> rect({vw, vh}, fill: c.bg)
      |> draw_ui(state, c)

    scene
    |> assign(state: state)
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl Scenic.Scene
  def handle_event({:click, :connect_btn}, _from, scene) do
    state = scene.assigns.state
    Logger.info("Startup connect pressed; switching to main UX")
    Task.start(fn -> apply_connection(state) end)
    Scenic.ViewPort.set_root(scene.viewport, Probnik.Scene.Main, nil)
    {:noreply, scene}
  end

  def handle_event(_event, _from, scene), do: {:noreply, scene}

  @impl Scenic.Scene
  def handle_input({:viewport, {:reshape, {w, h}}}, _id, scene) do
    state = %{scene.assigns.state | viewport: {w, h}}
    graph = rebuild_graph(state)
    {:noreply, assign(scene, state: state) |> push_graph(graph)}
  end

  def handle_input(_input, _id, scene), do: {:noreply, scene}

  defp rebuild_graph(state) do
    c = ColorScheme.current()
    {vw, vh} = state.viewport

    Graph.build(font: :courier, font_size: 28)
    |> rect({vw, vh}, fill: c.bg)
    |> draw_ui(state, c)
  end

  defp draw_ui(graph, state, c) do
    {vw, _vh} = state.viewport
    padding_x = 80
    top = 200
    button_w = max(480, vw - padding_x * 2)
    button_h = 160
    button_styles = [font: :courier_bold, font_size: 48]

    graph
    |> text("Select Target",
      fill: c.primary,
      font: :courier_bold,
      font_size: 56,
      translate: {padding_x, top}
    )
    |> text("Remote target",
      fill: c.secondary,
      font: :courier_bold,
      font_size: 32,
      translate: {padding_x, top + 80}
    )
    |> text("#{state.remote_node}  (#{state.remote_host})",
      fill: c.primary,
      font: :courier_bold,
      font_size: 34,
      translate: {padding_x, top + 140}
    )
    |> Components.button("Connect to one@super-io",
      id: :connect_btn,
      width: button_w,
      height: button_h,
      theme: :primary,
      styles: button_styles,
      translate: {padding_x, top + 260}
    )
  end

  defp apply_connection(%{token: token, remote_node: remote, remote_host: host}) do
    Logger.info("apply_connection remote=#{inspect(remote)} host=#{inspect(host)} token=#{inspect(token)}")
    {remote_node, remote_host} = normalize_remote_target(remote, host)

    Application.put_env(:probnik, :remote_enable, true)
    Application.put_env(:probnik, :remote_node, remote_node)
    Application.put_env(:probnik, :remote_host, remote_host)

    cookie = String.to_atom(token)

    ensure_node_started(remote_node)

    if Node.alive?() do
      :erlang.set_cookie(Node.self(), cookie)
      Logger.info("cookie set to #{inspect(cookie)} for local=#{inspect(Node.self())}")
    else
      Logger.warning("local node not alive; cookie not set")
    end

    start_remote_manager()
  end

  defp ensure_node_started(remote_node) do
    if Node.alive?() do
      Logger.info("local node already alive: #{inspect(Node.self())}")
      :ok
    else
      start_epmd()
      remote_host = remote_host_from_node(remote_node)
      mode = if String.contains?(remote_host, "."), do: :longnames, else: :shortnames
      local_host = Application.get_env(:probnik, :local_node_host) || local_hostname(mode)
      name = :"probnik@#{local_host}"
      Logger.info("starting net_kernel name=#{inspect(name)} mode=#{inspect(mode)} remote=#{inspect(remote_node)}")

      case :net_kernel.start([name, mode]) do
        {:ok, _} ->
          Logger.info("net_kernel started: #{inspect(Node.self())}")
          :ok

        {:error, {:already_started, _}} ->
          Logger.info("net_kernel already started: #{inspect(Node.self())}")
          :ok

        other ->
          Logger.warning("Failed to start net_kernel: #{inspect(other)}")
      end
    end
  end

  defp start_epmd do
    case System.get_env("BINDIR") do
      nil ->
        Logger.warning("BINDIR not set; cannot start epmd")

      bindir ->
        epmd = Path.join(bindir, "epmd")
        Logger.info("starting epmd via #{epmd} -daemon")
        _ = :os.cmd(String.to_charlist("#{epmd} -daemon"))
        :ok
    end
  end

  defp start_remote_manager do
    case Process.whereis(Probnik.RemoteNode) do
      nil ->
        Supervisor.start_child(Probnik.Supervisor, {Probnik.RemoteNode, []})
        :ok

      _ ->
        :ok
    end
  end

  defp normalize_remote_target(remote_node, remote_host) do
    {name, host_from_node} = split_node(remote_node)
    host = host_from_node || remote_host

    case normalize_host(host) do
      {:ok, normalized_host} ->
        {:"#{name}@#{normalized_host}", normalized_host}

      {:error, _} ->
        Logger.warning(
          "Remote host #{inspect(host)} is not a valid Erlang node host. Use a hostname or /etc/hosts entry."
        )

        {remote_node, host || ""}
    end
  end

  defp split_node(node) when is_atom(node), do: split_node(Atom.to_string(node))
  defp split_node(node) when is_binary(node) do
    case String.split(node, "@") do
      [name, host] -> {name, host}
      [name] -> {name, nil}
      _ -> {node, nil}
    end
  end

  defp normalize_host(nil), do: {:error, :no_host}
  defp normalize_host(host) do
    cond do
      host == "192.168.0.249" -> {:ok, "super-io"}
      ip_address?(host) ->
        case reverse_lookup_host(host) do
          {:ok, name} -> {:ok, name}
          {:error, _} -> {:error, :ip_not_allowed}
        end
      true -> {:ok, host}
    end
  end

  defp ip_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp reverse_lookup_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} ->
        case :inet.gethostbyaddr(addr) do
          {:ok, {:hostent, name, _aliases, _af, _len, _addrs}} ->
            {:ok, to_string(name)}

          _ ->
            {:error, :no_reverse}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp remote_host_from_node(node) when is_atom(node), do: remote_host_from_node(Atom.to_string(node))
  defp remote_host_from_node(node) when is_binary(node) do
    case String.split(node, "@") do
      [_, host] -> host
      _ -> "localhost"
    end
  end

  defp local_hostname(:shortnames) do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end

  defp local_hostname(:longnames) do
    {:ok, host} = :inet.gethostname()
    hostname = to_string(host)

    if String.contains?(hostname, ".") do
      hostname
    else
      hostname <> ".local"
    end
  end
end
