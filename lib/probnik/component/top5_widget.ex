defmodule Probnik.Component.Top5Widget do
  @moduledoc """
  Top 5 processes widget using recon.
  Shows either memory or message_queue_len top consumers.
  Big letters, designed for horizontal split layout.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 1000
  @base_width 600
  @base_height 450

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 600)
    height = Keyword.get(opts, :height, 450)
    # :memory or :message_queue_len
    attribute = Keyword.get(opts, :attribute, :memory)
    title = Keyword.get(opts, :title, "Top 5")

    scale = min(width / @base_width, height / @base_height)
    header_h = max(12, round(60 * scale))
    config = %{
      width: width,
      height: height,
      attribute: attribute,
      title: title,
      scale: scale,
      header_height: header_h
    }

    procs = fetch_top5(config.attribute)
    graph = build_graph(procs, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(config: config, procs: procs)
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl GenServer
  def handle_info(:refresh, scene) do
    %{config: config} = scene.assigns

    procs = fetch_top5(config.attribute)
    graph = build_graph(procs, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(procs: procs)
    |> push_graph(graph)
    |> then(&{:noreply, &1})
  end

  defp fetch_top5(attribute) do
    target = Probnik.Application.target_node()

    if remote_target?(target) do
      case :rpc.call(target, :recon, :proc_count, [attribute, 5], 5000) do
        {:badrpc, _reason} ->
          []

        result when is_list(result) ->
          Enum.map(result, fn {pid, value, info} ->
            # Get the real initial call like LiveDashboard does
            real_initial_call = :rpc.call(target, :proc_lib, :initial_call, [pid], 2000)
            %{pid: pid, value: value, name: extract_name(info, real_initial_call)}
          end)

        _ ->
          []
      end
    else
      :recon.proc_count(attribute, 5)
      |> Enum.map(fn {pid, value, info} ->
        real_initial_call = :proc_lib.initial_call(pid)
        %{pid: pid, value: value, name: extract_name(info, real_initial_call)}
      end)
    end
  rescue
    _ -> []
  end

  defp remote_target?(target) do
    target != Node.self() and Node.alive?() and Enum.member?(Node.list(), target)
  end

  defp extract_name(info, real_initial_call) when is_list(info) do
    reg_name = Keyword.get(info, :registered_name)

    cond do
      # First: registered name
      is_atom(reg_name) and reg_name not in [nil, []] ->
        Atom.to_string(reg_name)

      # Second: real initial call from proc_lib (like LiveDashboard)
      is_tuple(real_initial_call) and tuple_size(real_initial_call) == 3 ->
        extract_mfa(real_initial_call)

      # Fallback
      true ->
        "-"
    end
  end

  defp extract_name(_, _), do: "-"

  # Extract Module.Function for cleaner display
  defp extract_mfa({m, f, _a}) when is_atom(m) and is_atom(f) do
    module =
      m
      |> Atom.to_string()
      |> String.replace("Elixir.", "")

    "#{module}.#{f}"
  end

  defp extract_mfa(other), do: inspect(other)

  defp build_graph(procs, config) do
    c = ColorScheme.current()

    s = config.scale
    Graph.build(font: :courier, font_size: max(12, round(36 * s)))
    |> rect({config.width, config.height}, fill: c.bg, stroke: {max(1, round(2 * s)), c.border})
    |> draw_rows(procs, config, c)
    |> draw_watermark(config, c, procs)
  end

  defp draw_rows(graph, procs, config, c) do
    s = config.scale
    top_pad = 8 * s
    rows_height = config.height - top_pad * 2
    row_height = rows_height / 5
    procs
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_row(g, proc, idx, config, c, row_height)
    end)
  end

  defp draw_row(graph, proc, idx, config, c, row_height) do
    s = config.scale
    top_pad = 8 * s
    y = top_pad + (idx - 1) * row_height

    # Rank number
    rank_str = "#{idx}."

    # Process name - THE MOST VISIBLE ELEMENT (Module.Function)
    name_str = truncate(proc.name, 45)

    # Value formatting depends on attribute
    value_str = format_value(proc.value, config.attribute)

    # Color based on ranking
    rank_color =
      case idx do
        1 -> c.critical
        2 -> c.warning
        3 -> c.accent
        _ -> c.secondary
      end

    graph
    # Rank - small, left side
    |> text(rank_str,
      fill: rank_color,
      font_size: max(12, round(row_height * 0.8)),
      translate: {15 * s, y + row_height * 0.8}
    )
    # NAME - BIG AND PROMINENT
    |> text(name_str,
      fill: c.primary,
      font_size: max(12, round(48 * s)),
      translate: {60 * s, y + row_height * 0.6}
    )
    # Value - smaller, right aligned
    |> text(value_str,
      fill: rank_color,
      font_size: max(12, round(row_height * 0.8)),
      text_align: :right,
      translate: {config.width - 20 * s, y + row_height * 0.8}
    )
  end

  defp draw_watermark(graph, config, c, procs) do
    s = config.scale
    area_w = config.width * 0.4
    area_h = config.height * 0.4
    label_font = max(12, round(min(area_w, area_h) * 0.35))
    value_font = max(10, round(min(area_w, area_h) * 0.2)) * 4
    x = config.width - 12 * s
    y = config.height - 12 * s
    label = if config.attribute == :memory, do: "PROC MEM", else: "PROC MSGQ"
    value = top5_total(procs, config.attribute)

    graph
    |> text(value,
      fill: {255, 140, 0},
      font: :courier_bold,
      font_size: value_font,
      text_align: :right,
      translate: {x, y - label_font * 2.6}
    )
    |> text(label,
      fill: with_alpha(c.secondary, 80),
      font: :courier_bold,
      font_size: label_font,
      text_align: :right,
      translate: {x, y}
    )
  end

  defp with_alpha({r, g, b}, a), do: {r, g, b, a}
  defp with_alpha({r, g, b, _}, a), do: {r, g, b, a}

  defp top5_total(procs, :memory) do
    bytes = procs |> Enum.map(&(&1.value || 0)) |> Enum.sum()
    mb = bytes / 1024 / 1024
    Integer.to_string(round(mb))
  end

  defp top5_total(procs, :message_queue_len) do
    procs |> Enum.map(&(&1.value || 0)) |> Enum.sum() |> Integer.to_string()
  end

  defp top5_total(procs, _), do: procs |> Enum.map(&(&1.value || 0)) |> Enum.sum() |> Integer.to_string()

  defp truncate(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 2) <> ".."
    else
      str
    end
  end

  defp truncate(other, max_len), do: truncate(inspect(other), max_len)

  defp format_value(bytes, :memory) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{round(bytes / 1024)} KB"
      true -> "#{round(bytes / 1024 / 1024)} MB"
    end
  end

  defp format_value(count, :message_queue_len) do
    cond do
      count < 1000 -> "#{count}"
      count < 1_000_000 -> "#{Float.round(count / 1000, 1)}K"
      true -> "#{Float.round(count / 1_000_000, 1)}M"
    end
  end

  defp format_value(value, _), do: inspect(value)
end
