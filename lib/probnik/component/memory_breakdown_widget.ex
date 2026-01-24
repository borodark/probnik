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
    |> draw_total(data.total, c)
    |> draw_rows(data.rows, data.total, config, c)
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

  defp draw_total(graph, total, c) do
    graph
    |> text("Total: #{format_mb(total)}",
      fill: c.secondary,
      font: :courier,
      font_size: 22,
      translate: {20, @header_height + 35}
    )
  end

  defp draw_rows(graph, rows, total, config, c) do
    start_y = @header_height + 60
    bar_x = 220
    bar_width = config.width - bar_x - 30

    rows
    |> Enum.with_index(0)
    |> Enum.reduce(graph, fn {row, idx}, g ->
      y = start_y + idx * @row_height
      ratio = if total > 0, do: row.value / total, else: 0.0
      fill_w = bar_width * ratio
      color = row_color(row.key, c)

      g
      |> text(row.label,
        fill: c.primary,
        font: :courier,
      font_size: 20,
        translate: {20, y + 35}
      )
      |> text(format_mb(row.value),
        fill: c.secondary,
        font: :courier,
      font_size: 20,
        text_align: :right,
        translate: {bar_x - 10, y + 35}
      )
      |> rrect({bar_width, 24, 4},
        fill: dim_color(c.primary, 0.15),
        translate: {bar_x, y + 15}
      )
      |> rrect({fill_w, 24, 4},
        fill: color,
        translate: {bar_x, y + 15}
      )
      |> text(pct(ratio),
        fill: c.bg,
        font: :courier,
        font_size: 18,
        translate: {bar_x + 8, y + 32}
      )
    end)
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
