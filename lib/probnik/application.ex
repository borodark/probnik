defmodule Probnik.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    main_viewport_config = Application.get_env(:probnik, :viewport)

    if remote_enabled?() do
      Probnik.RemoteConnect.ensure_connected()
    end

    children =
      if main_viewport_config do
        [{Scenic, [main_viewport_config]}]
      else
        []
      end

    # Add RemoteNode connection manager when explicitly enabled
    children =
      if remote_enabled?() do
        [{Probnik.RemoteNode, []} | children]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Probnik.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def target_node do
    cond do
      remote_enabled?() and Probnik.RemoteNode.connected?() ->
        Probnik.RemoteNode.remote_node()

      true ->
        Node.self()
    end
  end

  defp remote_enabled? do
    Application.get_env(:probnik, :remote_enable, false) or
      System.get_env("PROBNIK_REMOTE_ENABLE") in ["1", "true", "TRUE", "yes", "YES"]
  end
end
