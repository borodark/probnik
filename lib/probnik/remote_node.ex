defmodule Probnik.RemoteNode do
  @moduledoc """
  Handles connection to remote Erlang node on Android.
  """

  use GenServer
  require Logger

  @default_remote_host "192.168.0.249"
  @default_remote_node :"one@192.168.0.249"
  @retry_interval 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    remote = remote_node()
    Logger.info("[RemoteNode] Starting connection manager for #{remote}")
    Logger.info("[RemoteNode] Local node: #{Node.self()}")
    Logger.info("[RemoteNode] Cookie: #{Node.get_cookie()}")
    send(self(), :connect)
    {:ok, %{connected: false, attempts: 0, remote_node: remote}}
  end

  @impl true
  def handle_info(:connect, %{remote_node: remote} = state) do
    case Node.connect(remote) do
      true ->
        Logger.info("[RemoteNode] Connected to #{remote}")
        Node.monitor(remote, true)
        {:noreply, %{state | connected: true, attempts: 0}}

      false ->
        attempts = state.attempts + 1
        Logger.warning("[RemoteNode] Failed to connect to #{remote} (attempt #{attempts}), retrying in #{@retry_interval}ms")
        Process.send_after(self(), :connect, @retry_interval)
        {:noreply, %{state | connected: false, attempts: attempts}}

      :ignored ->
        Logger.warning("[RemoteNode] Node.connect returned :ignored - local node may not be alive")
        Logger.info("[RemoteNode] Node.alive? = #{Node.alive?()}")
        Process.send_after(self(), :connect, @retry_interval)
        {:noreply, %{state | connected: false}}
    end
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("[RemoteNode] Lost connection to #{node}, reconnecting...")
    send(self(), :connect)
    {:noreply, %{state | connected: false}}
  end

  def connected? do
    Node.list() |> Enum.member?(remote_node())
  end

  def remote_node do
    Application.get_env(:probnik, :remote_node, @default_remote_node)
  end

  def remote_host do
    Application.get_env(:probnik, :remote_host, @default_remote_host)
  end
end
