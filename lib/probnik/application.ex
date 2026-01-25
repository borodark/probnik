defmodule Probnik.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    main_viewport_config = Application.get_env(:probnik, :viewport)
    is_android = is_android?()

    children =
      if main_viewport_config do
        [{Scenic, [main_viewport_config]}]
      else
        []
      end

    # Add RemoteNode connection manager on Android
    children =
      if is_android do
        [{Probnik.RemoteNode, []} | children]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Probnik.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp is_android? do
    System.get_env("ANDROID_ROOT") != nil or File.exists?("/system/build.prop")
  end

  def target_node do
    if is_android?() do
      Probnik.RemoteNode.remote_node()
    else
      :"one@localhost"
    end
  end
end
