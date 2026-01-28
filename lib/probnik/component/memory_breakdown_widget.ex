defmodule Probnik.Component.MemoryBreakdownWidget do
  @moduledoc """
  Memory breakdown widget.
  Shows total memory and distribution across processes, ETS, binary, and code.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Scenic.Assets.Static
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 2000
  @base_width 1600
  @base_height 600

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 800)
    height = Keyword.get(opts, :height, 600)
    title = Keyword.get(opts, :title, "MEMORY BREAKDOWN")

    scale = min(width / @base_width, height / @base_height)
    config = %{
      width: width,
      height: height,
      title: title,
      scale: scale
    }

    data = fetch_data()
    graph = build_graph(data, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(config: config, data: data)
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl GenServer
  def handle_info(:refresh, scene) do
    %{config: config} = scene.assigns

    data = fetch_data()
    graph = build_graph(data, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(data: data)
    |> push_graph(graph)
    |> then(&{:noreply, &1})
  end

  defp fetch_data do
    target = Probnik.Application.target_node()

    mem =
      case :rpc.call(target, :erlang, :memory, [], 4000) do
        {:badrpc, _} -> :erlang.memory()
        result -> result
      end

    mem_map =
      cond do
        is_map(mem) -> mem
        is_list(mem) -> Enum.into(mem, %{})
        true -> %{}
      end

    total = Map.get(mem_map, :total, 0)
    processes = Map.get(mem_map, :processes, 0)
    ets = Map.get(mem_map, :ets, 0)
    binary = Map.get(mem_map, :binary, 0)
    code = Map.get(mem_map, :code, 0)

    sum = processes + ets + binary + code
    other = max(total - sum, 0)

    %{
      total: total,
      rows: [
        %{label: "Processes", value: processes, key: :processes},
        %{label: "ETS", value: ets, key: :ets},
        %{label: "Binary", value: binary, key: :binary},
        %{label: "Code", value: code, key: :code},
        %{label: "Other", value: other, key: :other}
      ]
    }
  rescue
    _ -> %{total: 0, rows: []}
  end

  defp build_graph(%{rows: []} = _data, config) do
    c = ColorScheme.current()

    s = config.scale
    Graph.build(font: :courier, font_size: max(10, round(22 * s)))
    |> rect({config.width, config.height}, fill: c.bg, stroke: {max(1, round(2 * s)), c.border})
    |> text("No data - check node connection",
      fill: c.warning,
      font: :courier,
      font_size: max(12, round(28 * s)),
      translate: {20 * s, config.height / 2}
    )
  end

  defp build_graph(data, config) do
    c = ColorScheme.current()

    s = config.scale
    Graph.build(font: :courier, font_size: max(12, round(24 * s)))
    |> rect({config.width, config.height}, fill: c.bg, stroke: {max(1, round(2 * s)), c.border})
    #|> draw_category_bars(data.rows, data.total, config, c)
    |> draw_sorted_bars(data.rows, data.total, config, c)
    |> draw_watermark(config, c)
  end

  defp draw_sorted_bars(graph, rows, total, config, c) do
    # Sorted horizontal bars: biggest on the left, smallest on the right
    sorted = Enum.sort_by(rows, & &1.value, :desc)
    s = config.scale
    top_pad = 8 * s
    start_y = top_pad
    bar_x = 20 * s
    bar_width = config.width - 40 * s
    row_height = (config.height - start_y - 8 * s) / max(length(sorted), 1)
    bar_height = max(row_height * 0.85, 18 * s)
    label_size = max(trunc(row_height * 0.8), round(16 * s))
    value_size = max(trunc(row_height * 0.8), round(14 * s))

    sorted
    |> Enum.with_index(0)
    |> Enum.reduce(graph, fn {row, idx}, g ->
      y = start_y + idx * row_height
      ratio = if total > 0, do: row.value / total, else: 0.0
      fill_w = bar_width * ratio
      color = rank_color(idx, c)

      g
      |> rect({fill_w, bar_height},
        fill: color,
        translate: {bar_x, y + row_height * 0.1}
      )
      |> draw_inverted_left_text(
        row.label,
        :courier_bold,
        label_size,
        bar_x + 12 * s,
        y + row_height * 0.8,
        bar_x + fill_w,
        c.secondary
      )
      |> draw_inverted_right_text(
        format_mb(row.value),
        :courier_bold,
        value_size,
        bar_x + bar_width,
        y + row_height * 0.8,
        bar_x + fill_w,
        c.secondary
      )
    end)
  end

  defp rank_color(idx, c) do
    case idx do
      0 -> c.critical
      1 -> {255, 180, 0}
      2 -> {200, 170, 0}
      3 -> {255, 210, 0}
      _ -> {255, 120, 0}
    end
  end


  defp format_mb(bytes) when is_integer(bytes) do
    mb = bytes / 1024 / 1024
    Integer.to_string(round(mb))
  end

  defp format_mb(_), do: "0"

  defp draw_watermark(graph, config, c) do
    s = config.scale
    area_w = config.width * 0.4
    area_h = config.height * 0.4
    font_size = max(12, round(min(area_w, area_h) * 0.35))
    x = config.width - 12 * s - config.width * 0.25
    y = config.height - 12 * s
    label = "MEM BRKDN MB"

    graph
    |> text(label,
      fill: with_alpha(c.secondary, 80),
      font: :courier_bold,
      font_size: font_size,
      text_align: :right,
      translate: {x, y}
    )
  end

  defp with_alpha({r, g, b}, a), do: {r, g, b, a}
  defp with_alpha({r, g, b, _}, a), do: {r, g, b, a}

  defp draw_inverted_left_text(graph, text, font, font_size, x, y, fill_limit, base_color) do
    {:ok, {Static.Font, fm}} = Static.meta(font)

    text
    |> String.graphemes()
    |> Enum.reduce({graph, x}, fn ch, {g, cx} ->
      w = FontMetrics.width(ch, font_size, fm)
      color = if fill_limit >= cx + w / 2, do: {0, 0, 0}, else: base_color

      g =
        g
        |> text(ch,
          fill: color,
          font: font,
          font_size: font_size,
          translate: {cx, y}
        )

      {g, cx + w}
    end)
    |> elem(0)
  end

  defp draw_inverted_right_text(graph, text, font, font_size, right_x, y, fill_limit, base_color) do
    {:ok, {Static.Font, fm}} = Static.meta(font)
    total_w = FontMetrics.width(text, font_size, fm)
    start_x = right_x - total_w

    text
    |> String.graphemes()
    |> Enum.reduce({graph, start_x}, fn ch, {g, cx} ->
      w = FontMetrics.width(ch, font_size, fm)
      color = if fill_limit >= cx + w / 2, do: {0, 0, 0}, else: base_color

      g =
        g
        |> text(ch,
          fill: color,
          font: font,
          font_size: font_size,
          translate: {cx, y}
        )

      {g, cx + w}
    end)
    |> elem(0)
  end

end
