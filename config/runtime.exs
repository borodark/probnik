import Config

# Detect Android environment
is_android = System.get_env("ANDROID_ROOT") != nil or
             File.exists?("/system/build.prop")

IO.puts("runtime.exs loaded - is_android=#{is_android}")

if is_android do
  IO.puts("runtime.exs: Android detected, configuring Scenic.Driver.Android")
  # Remote node configuration
  config :probnik,
    remote_host: "super-io",
    remote_node: :"one@super-io",
    remote_enable: true,
    remote_cookie: "secret_token",
    local_node_host: "probnik"

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
