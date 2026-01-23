defmodule Probnik.ColorScheme do
  @moduledoc """
  Color scheme definitions.

  Available schemes:
  - :dark_bmw - Warm amber/orange/red spectrum
  - :sunny_day - High contrast white/cyan/green for bright sunlight

  Configure in config.exs:
      config :probnik, :color_scheme, :sunny_day
  """

  def current do
    scheme = Application.get_env(:probnik, :color_scheme, :dark_bmw)
    get(scheme)
  end

  def get(scheme \\ :dark_bmw)

  def get(:dark_bmw) do
    %{
      bg: {0, 0, 0},
      primary: {255, 180, 0},
      secondary: {255, 140, 0},
      accent: {255, 220, 0},
      border: {255, 100, 0},
      tick: {255, 30, 0},
      needle: {255, 140, 0},
      warning: {255, 220, 0},
      critical: {255, 0, 0},
      positive: {255, 220, 0},
      negative: {255, 0, 0},
      arc_white: {255, 200, 150},
      arc_green: {200, 180, 0},
      arc_yellow: {255, 180, 0},
      arc_red: {255, 0, 0},
      sky: {30, 60, 130},
      ground: {140, 90, 50},
      horizon: {255, 220, 0},
      cardinal: {255, 220, 0},
      aircraft: {255, 140, 0}
    }
  end

  def get(:sunny_day) do
    %{
      bg: {0, 0, 0},
      primary: {255, 255, 255},
      secondary: {0, 255, 255},
      accent: {0, 255, 128},
      border: {255, 255, 255},
      tick: {0, 255, 255},
      needle: {255, 255, 255},
      warning: {255, 255, 0},
      critical: {255, 0, 128},
      positive: {0, 255, 128},
      negative: {255, 0, 128},
      arc_white: {255, 255, 255},
      arc_green: {0, 255, 100},
      arc_yellow: {255, 255, 0},
      arc_red: {255, 0, 128},
      sky: {0, 100, 200},
      ground: {139, 90, 43},
      horizon: {255, 255, 255},
      cardinal: {0, 255, 128},
      aircraft: {255, 255, 255}
    }
  end

  def color(scheme, key), do: get(scheme)[key]

  def schemes, do: [:dark_bmw, :sunny_day]
end
