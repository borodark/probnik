import Config

# Detect Android environment
is_android = System.get_env("ANDROID_ROOT") != nil or
             File.exists?("/system/build.prop")

if is_android do
  # Remote node configuration
  config :probnik,
    remote_host: "192.168.0.249",
    remote_node: :"one@192.168.0.249"

  # Scenic viewport configuration
  config :probnik, :viewport,
    name: :main_viewport,
    size: {1080, 1920},
    default_scene: Probnik.Scene.Main,
    drivers: [
      [
        module: Scenic.Driver.Android,
        name: :android,
        socket_path: "/data/data/com.probnik/cache/scenic.sock"
      ]
    ]

  # Enable distributed Erlang logging
  config :logger, level: :info
end
