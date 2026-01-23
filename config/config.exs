import Config

config :scenic, :assets, module: Probnik.Assets

config :probnik, color_scheme: :sunny_day #:dark_bmw

config :probnik, :viewport,
  name: :main_viewport,
  size: {2388, 1668},
  default_scene: Probnik.Scene.Main,
  drivers: [
    [
      module: Scenic.Driver.Local,
      name: :local,
      window: [title: "Probnik", resizeable: false]
    ]
  ]
