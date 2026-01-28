defmodule Probnik.RemoteConnect do
  @moduledoc false

  require Logger

  @default_remote_node :"one@super-io"
  @default_remote_host "super-io"
  @default_cookie "secret_token"

  def ensure_connected do
    remote_node = Application.get_env(:probnik, :remote_node, @default_remote_node)
    remote_host = Application.get_env(:probnik, :remote_host, @default_remote_host)
    cookie = Application.get_env(:probnik, :remote_cookie, @default_cookie)

    Application.put_env(:probnik, :remote_enable, true)
    Application.put_env(:probnik, :remote_node, remote_node)
    Application.put_env(:probnik, :remote_host, remote_host)

    ensure_node_started(remote_node)

    if Node.alive?() do
      :erlang.set_cookie(Node.self(), String.to_atom(cookie))
      Logger.info("RemoteConnect: cookie set for local=#{inspect(Node.self())}")
    else
      Logger.warning("RemoteConnect: local node not alive; cookie not set")
    end
  end

  defp ensure_node_started(remote_node) do
    if Node.alive?() do
      :ok
    else
      start_epmd()
      remote_host = remote_host_from_node(remote_node)
      mode = if String.contains?(remote_host, "."), do: :longnames, else: :shortnames
      local_host = Application.get_env(:probnik, :local_node_host) || local_hostname(mode)
      name = :"probnik@#{local_host}"
      Logger.info("RemoteConnect: starting net_kernel name=#{inspect(name)} mode=#{inspect(mode)}")

      case :net_kernel.start([name, mode]) do
        {:ok, _} ->
          Logger.info("RemoteConnect: net_kernel started: #{inspect(Node.self())}")
          :ok

        {:error, {:already_started, _}} ->
          :ok

        other ->
          Logger.warning("RemoteConnect: failed to start net_kernel: #{inspect(other)}")
          :error
      end
    end
  end

  defp start_epmd do
    epmd =
      System.get_env("BINDIR")
      |> case do
        nil -> System.find_executable("epmd")
        bindir -> Path.join(bindir, "epmd")
      end

    if epmd do
      Logger.info("RemoteConnect: starting epmd via #{epmd} -daemon")
      _ = :os.cmd(String.to_charlist("#{epmd} -daemon"))
    else
      Logger.warning("RemoteConnect: epmd not found (BINDIR unset and not in PATH)")
    end
  end

  defp remote_host_from_node(node) when is_atom(node),
    do: remote_host_from_node(Atom.to_string(node))

  defp remote_host_from_node(node) when is_binary(node) do
    case String.split(node, "@") do
      [_, host] -> host
      _ -> @default_remote_host
    end
  end

  defp local_hostname(:shortnames) do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end

  defp local_hostname(:longnames) do
    {:ok, host} = :inet.gethostname()
    hostname = to_string(host)

    if String.contains?(hostname, ".") do
      hostname
    else
      hostname <> ".local"
    end
  end
end
