import Config

config :scenic, :assets, module: Probnik.Assets

config :probnik, color_scheme: :dark_bmw  #:sunny_day

config :probnik, :viewport,
  name: :main_viewport,
  size: {1668, 2388},  # Portrait orientation
  default_scene: Probnik.Scene.Main,
  drivers: [
    [
      module: Scenic.Driver.Local,
      name: :local,
      window: [title: "Probnik - Node Health", resizeable: false]
    ]
  ]

config :probnik,
  remote_enable: true,
  remote_host: "super-io",
  remote_node: :"one@super-io",
  remote_cookie: "secret_token",
  local_node_host: "probnik"
