import Config

# Detect Android environment
is_android = System.get_env("ANDROID_ROOT") != nil or
             File.exists?("/system/build.prop")

IO.puts("runtime.exs loaded - is_android=#{is_android}")

if is_android do
  IO.puts("runtime.exs: Android detected, configuring Scenic.Driver.Android")

  # Read connection config from file written by Android native code
  # File format: {node, 'one@super-io'}. {cookie, 'secret_token'}. {mode, shortnames}.
  config_path = ~c"/data/data/com.probnik/files/connection.config"

  connection_config =
    case :file.consult(config_path) do
      {:ok, terms} ->
        # Convert list of tuples to map
        Enum.into(terms, %{})
      {:error, reason} ->
        IO.puts("runtime.exs: No connection.config found (#{inspect(reason)}), using defaults")
        %{}
    end

  # Extract values with defaults
  remote_node = Map.get(connection_config, :node, :"one@super-io")
  remote_cookie = Map.get(connection_config, :cookie, :"secret_token") |> to_string()
  mode = Map.get(connection_config, :mode, :shortnames)

  # Derive host from node name
  remote_host =
    case Atom.to_string(remote_node) |> String.split("@") do
      [_, host] -> host
      _ -> "super-io"
    end

  IO.puts("runtime.exs: remote_node=#{remote_node} host=#{remote_host} mode=#{mode}")

  # Remote node configuration
  config :probnik,
    remote_host: remote_host,
    remote_node: remote_node,
    remote_enable: true,
    remote_cookie: remote_cookie,
    local_node_host: "probnik",
    name_mode: mode

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
