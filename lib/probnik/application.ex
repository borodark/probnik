defmodule Probnik.Application do
  @moduledoc false
  use Application

  @target_node :"one@localhost"

  @impl true
  def start(_type, _args) do
    # Connect to target node
    connect_to_target()

    main_viewport_config = Application.get_env(:probnik, :viewport)

    children = [
      {Scenic, [main_viewport_config]}
    ]

    opts = [strategy: :one_for_one, name: Probnik.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp connect_to_target do
    case Node.connect(@target_node) do
      true ->
        IO.puts("Connected to #{@target_node}")

      false ->
        IO.puts("Failed to connect to #{@target_node}")

      :ignored ->
        IO.puts("Local node not alive, cannot connect")
    end
  end

  def target_node, do: @target_node
end
