defmodule Probnik.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    main_viewport_config = Application.get_env(:probnik, :viewport)

    children = [
      {Scenic, [main_viewport_config]}
    ]

    opts = [strategy: :one_for_one, name: Probnik.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
