defmodule Probnik.Discovery do
  @moduledoc """
  Discover Erlang nodes on the LAN by scanning for epmd on port 4369.
  """

import Bitwise

  @epmd_port 4369
  @scan_timeout 200
  @max_hosts 256

  def scan do
    local_ips()
    |> Enum.flat_map(&scan_subnet/1)
    |> Enum.uniq_by(& &1.host)
  end

  defp scan_subnet({ip, mask}) do
    {a, b, c, _d} = ip
    prefix = mask_to_prefix(mask)

    {net_a, net_b, net_c, _} = apply_mask(ip, mask)
    base_c = net_c

    hosts =
      cond do
        prefix >= 24 ->
          Enum.map(1..254, fn i -> {net_a, net_b, base_c, i} end)

        true ->
          # Fallback to /24 around the local ip to avoid huge scans
          Enum.map(1..254, fn i -> {a, b, c, i} end)
      end
      |> Enum.reject(fn addr -> addr == ip end)

    hosts
    |> Task.async_stream(&probe_epmd/1, max_concurrency: 64, timeout: @scan_timeout + 50)
    |> Enum.reduce([], fn
      {:ok, {:ok, entry}}, acc -> [entry | acc]
      _, acc -> acc
    end)
  end

  defp probe_epmd({a, b, c, d} = addr) do
    case :gen_tcp.connect(addr, @epmd_port, [:binary, active: false], @scan_timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        host = "#{a}.#{b}.#{c}.#{d}"

        case :net_adm.names(String.to_charlist(host)) do
          {:ok, names} when is_list(names) and names != [] ->
            nodes =
              Enum.map(names, fn {name, _port} ->
                "#{name}@#{host}"
              end)

            {:ok, %{host: host, nodes: nodes}}

          _ ->
            {:error, :no_names}
        end

      _ ->
        {:error, :no_epmd}
    end
  end

  defp local_ips do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        ifs
        |> Enum.flat_map(fn {_ifname, props} ->
          addr = Keyword.get(props, :addr)
          mask = Keyword.get(props, :netmask)
          flags = Keyword.get(props, :flags, [])

          case {addr, mask} do
            {{a, b, c, d}, {m1, m2, m3, m4}}
            when a in 1..223 and {a, b, c, d} != {127, 0, 0, 1} ->
              if loopback_flag?(flags) do
                []
              else
                [{{a, b, c, d}, {m1, m2, m3, m4}}]
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp loopback_flag?(flags) when is_list(flags) do
    Enum.member?(flags, :loopback)
  end

  defp mask_to_prefix({m1, m2, m3, m4}) do
    [m1, m2, m3, m4]
    |> Enum.map(&Integer.to_string(&1, 2))
    |> Enum.map(&String.pad_leading(&1, 8, "0"))
    |> Enum.join()
    |> String.graphemes()
    |> Enum.take_while(&(&1 == "1"))
    |> length()
  end

  defp apply_mask({a, b, c, d}, {m1, m2, m3, m4}) do
    {a &&& m1, b &&& m2, c &&& m3, d &&& m4}
  end
end
