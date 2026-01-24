defmodule Probnik.Component.MemoryBreakdownWidget do
  @moduledoc """
  Memory breakdown widget.
  Shows total memory and distribution across processes, ETS, binary, and code.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 2000
  @header_height 60
  @row_height 52

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 800)
    height = Keyword.get(opts, :height, 600)
    title = Keyword.get(opts, :title, "MEMORY BREAKDOWN")

    config = %{
      width: width,
      height: height,
      title: title
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

    Graph.build(font: :courier, font_size: 22)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> text("No data - check node connection",
      fill: c.warning,
      font: :courier,
      font_size: 28,
      translate: {20, config.height / 2}
    )
  end

  defp build_graph(data, config) do
    c = ColorScheme.current()

    Graph.build(font: :courier, font_size: 24)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> draw_header(config, c)
    #|> draw_category_bars(data.rows, data.total, config, c)
    |> draw_sorted_bars(data.rows, data.total, config, c)
  end

  defp draw_header(graph, config, c) do
    graph
    |> text(config.title,
      fill: c.primary,
      font: :courier,
      font_size: 32,
      translate: {20, 50}
    )
    |> line({{0, @header_height}, {config.width, @header_height}}, stroke: {2, c.border})
  end

  defp draw_category_bars(graph, rows, total, config, c) do
    # Transposed list into vertical bar diagram
    area_x = 30
    area_y = @header_height + 70
    area_width = config.width - 60
    label_band = 24
    area_height = config.height - area_y - label_band - 10
    count = max(length(rows), 1)
    gap = 14
    bar_width = max((area_width - gap * (count - 1)) / count, 18)

    rows
    |> Enum.with_index(0)
    |> Enum.reduce(graph, fn {row, idx}, g ->
      ratio = if total > 0, do: row.value / total, else: 0.0
      bar_h = area_height * ratio
      color = row_color(row.key, c)
      x = area_x + idx * (bar_width + gap)
      y = area_y + (area_height - bar_h)
      label_y = area_y + area_height + 18

      g
      |> rect({bar_width, bar_h},
        fill: color,
        translate: {x, y}
      )
      |> text(row.label,
        fill: c.primary,
        font: :courier,
        font_size: 18,
        text_align: :center,
        translate: {x + bar_width / 2, label_y}
      )
      |> text(format_mb(row.value),
        fill: c.secondary,
        font: :courier,
        font_size: 16,
        text_align: :center,
        translate: {x + bar_width / 2, y - 8}
      )
    end)
  end

  defp draw_sorted_bars(graph, rows, total, config, c) do
    # Sorted horizontal bars: biggest on the left, smallest on the right
    sorted = Enum.sort_by(rows, & &1.value, :desc)
    start_y = @header_height + 16
    bar_x = 20
    bar_width = config.width - 40
    row_height = (config.height - start_y - 12) / max(length(sorted), 1)
    bar_height = max(row_height * 0.7, 18)
    label_size = max(trunc(row_height * 0.42), 16)
    value_size = max(trunc(row_height * 0.36), 14)

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
        translate: {bar_x, y + row_height * 0.15}
      )
      |> text(row.label,
        fill: {0, 0, 0},
        font: :courier_bold,
        font_size: label_size,
        translate: {bar_x + 12, y + row_height * 0.6}
      )
      |> text(format_mb(row.value),
        fill: c.secondary,
        font: :courier_bold,
        font_size: value_size,
        text_align: :right,
        translate: {bar_x + bar_width, y + row_height * 0.6}
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

  defp row_color(key, c) do
    case key do
      :processes -> c.primary
      :ets -> c.warning
      :binary -> c.accent
      :code -> c.secondary
      :other -> c.border
      _ -> c.secondary
    end
  end

  defp format_mb(bytes) when is_integer(bytes) do
    mb = bytes / 1024 / 1024
    :erlang.float_to_binary(mb, decimals: 1) <> " MB"
  end

  defp format_mb(_), do: "0 MB"

  defp pct(ratio) when is_float(ratio) do
    :erlang.float_to_binary(ratio * 100, decimals: 1) <> "%"
  end

  defp pct(_), do: "0%"

  defp dim_color({r, g, b}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor)}
  end

  defp dim_color({r, g, b, a}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor), a}
  end
end
