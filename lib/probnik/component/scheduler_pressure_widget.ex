defmodule Probnik.Component.SchedulerPressureWidget do
  @moduledoc """
  Scheduler pressure widget.
  Shows per-scheduler utilization and run queue lengths.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 2000
  @header_height 60
  @info_height 50

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 800)
    height = Keyword.get(opts, :height, 600)
    title = Keyword.get(opts, :title, "SCHEDULER PRESSURE")

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

    schedulers_online =
      rpc_or_local(target, :erlang, :system_info, [:schedulers_online], fn ->
        :erlang.system_info(:schedulers_online)
      end)

    scheduler_usage =
      rpc_or_local(target, :recon, :scheduler_usage, [1000], fn ->
        :recon.scheduler_usage(1000)
      end)

    run_queue =
      rpc_or_local(target, :erlang, :statistics, [:run_queue], fn ->
        :erlang.statistics(:run_queue)
      end)

    run_queue_lengths =
      rpc_or_local(target, :erlang, :statistics, [:run_queue_lengths], fn ->
        :erlang.statistics(:run_queue_lengths)
      end)

    {rq_total, rq_lengths} = normalize_run_queue_lengths(run_queue, run_queue_lengths)
    schedulers = merge_scheduler_data(scheduler_usage, rq_lengths, schedulers_online)

    %{
      schedulers: schedulers,
      run_queue_total: rq_total,
      run_queue_lengths: rq_lengths,
      schedulers_online: schedulers_online
    }
  rescue
    _ -> %{schedulers: [], run_queue_total: 0, run_queue_lengths: [], schedulers_online: 0}
  end

  defp rpc_or_local(target, mod, fun, args, local_fun) do
    case :rpc.call(target, mod, fun, args, 4000) do
      {:badrpc, _} -> local_fun.()
      result -> result
    end
  rescue
    _ -> local_fun.()
  end

  defp normalize_run_queue_lengths(run_queue, run_queue_lengths) do
    rq_total =
      case run_queue do
        n when is_integer(n) -> n
        _ -> 0
      end

    case run_queue_lengths do
      {total, lengths} when is_integer(total) and is_list(lengths) ->
        {total, lengths}

      {total, lengths, _dirty_cpu, _dirty_io}
      when is_integer(total) and is_list(lengths) ->
        {total, lengths}

      lengths when is_list(lengths) ->
        {Enum.sum(lengths), lengths}

      _ ->
        {rq_total, []}
    end
  end

  defp merge_scheduler_data(scheduler_usage, rq_lengths, schedulers_online) do
    usage_map =
      case scheduler_usage do
        list when is_list(list) ->
          Map.new(list, fn {id, usage} -> {id, usage} end)

        _ ->
          %{}
      end

    count =
      cond do
        is_integer(schedulers_online) and schedulers_online > 0 ->
          schedulers_online

        rq_lengths != [] ->
          length(rq_lengths)

        map_size(usage_map) > 0 ->
          map_size(usage_map)

        true ->
          0
      end

    ids =
      if count > 0 do
        Enum.to_list(1..count)
      else
        []
      end

    Enum.map(ids, fn id ->
      %{
        id: id,
        usage: Map.get(usage_map, id, 0.0),
        run_queue: Enum.at(rq_lengths, id - 1, 0)
      }
    end)
  end

  defp build_graph(%{schedulers: []} = _data, config) do
    c = ColorScheme.current()

    Graph.build(font: :roboto_mono, font_size: 22)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> text("No data - check node connection",
      fill: c.warning,
      font: :roboto_mono,
      font_size: 28,
      translate: {20, config.height / 2}
    )
  end

  defp build_graph(data, config) do
    c = ColorScheme.current()
    schedulers = data.schedulers

    {avg_usage, max_usage} = usage_stats(schedulers)
    {avg_rq, max_rq, min_rq} = run_queue_stats(schedulers, data.run_queue_total)

    Graph.build(font: :roboto_mono, font_size: 24)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> draw_header(config, c)
    |> draw_info(data, config, avg_usage, max_usage, avg_rq, max_rq, min_rq, c)
    |> draw_rows(schedulers, avg_usage, max_usage, config, c)
  end

  defp draw_header(graph, config, c) do
    graph
    |> text(config.title,
      fill: c.primary,
      font: :roboto_mono,
      font_size: 32,
      translate: {20, 50}
    )
    |> line({{0, @header_height}, {config.width, @header_height}}, stroke: {2, c.border})
  end

  defp draw_info(graph, data, config, avg_usage, max_usage, avg_rq, max_rq, min_rq, c) do
    rq_skew = max_rq - min_rq
    avg_str = pct(avg_usage)
    max_str = pct(max_usage)

    graph
    |> text("RunQ total: #{data.run_queue_total}",
      fill: c.secondary,
      font: :roboto_mono,
      font_size: 20,
      translate: {20, @header_height + 35}
    )
    |> text("RunQ avg: #{format_float(avg_rq, 1)}  skew: #{rq_skew}",
      fill: c.secondary,
      font: :roboto_mono,
      font_size: 20,
      translate: {20, @header_height + 60}
    )
    |> text("Util avg: #{avg_str}  max: #{max_str}",
      fill: c.secondary,
      font: :roboto_mono,
      font_size: 20,
      translate: {config.width / 2 + 10, @header_height + 35}
    )
  end

  defp draw_rows(graph, schedulers, avg_usage, max_usage, config, c) do
    # Vertical bar chart: one bar per scheduler
    area_y = @header_height + @info_height
    area_height = config.height - area_y - 10
    area_x = 20
    area_width = config.width - 40
    count = max(length(schedulers), 1)
    gap = 0
    bar_width = max((area_width - gap * (count - 1)) / count, 6)
    overlap = 1
    graph =
      graph
      |> draw_tick(area_x, area_width, area_y, area_height, avg_usage, c.secondary)
      |> draw_tick(area_x, area_width, area_y, area_height, max_usage, c.critical)

    schedulers
    |> Enum.sort_by(& &1.usage, :desc)
    |> Enum.with_index(0)
    |> Enum.reduce(graph, fn {sched, idx}, g ->
      x = area_x + idx * (bar_width + gap) - min(idx, overlap)
      draw_bar(g, sched, x, area_y, bar_width + overlap, area_height, c)
    end)
  end

  defp draw_tick(graph, x, width, y, height, usage, color) do
    ratio = min(max(usage, 0.0), 1.0)
    y_pos = y + height - height * ratio

    graph
    |> line({{x, y_pos}, {x + width, y_pos}}, stroke: {2, color})
  end

  defp draw_bar(graph, sched, x, y, bar_width, area_height, c) do
    usage = sched.usage || 0.0
    usage_ratio = min(usage, 1.0)
    fill_h = area_height * usage_ratio
    rq = sched.run_queue || 0

    bar_color =
      cond do
        usage >= 1.0 -> c.critical
        usage >= 0.8 -> c.warning
        usage >= 0.5 -> c.accent
        true -> c.secondary
      end

    graph
    |> rect({bar_width, fill_h},
      fill: bar_color,
      translate: {x, y + (area_height - fill_h)}
    )
  end

  defp usage_stats(schedulers) do
    usages = Enum.map(schedulers, & &1.usage)
    avg = if usages == [], do: 0.0, else: Enum.sum(usages) / length(usages)
    max = if usages == [], do: 0.0, else: Enum.max(usages)
    {avg, max}
  end

  defp run_queue_stats(schedulers, rq_total) do
    lengths = Enum.map(schedulers, & &1.run_queue)
    max_rq = if lengths == [], do: 0, else: Enum.max(lengths)
    min_rq = if lengths == [], do: 0, else: Enum.min(lengths)
    avg_rq = if lengths == [], do: 0.0, else: rq_total / max(length(schedulers), 1)
    {avg_rq, max_rq, min_rq}
  end

  defp pct(val) when is_float(val) do
    format_float(val * 100, 1) <> "%"
  end

  defp pct(val) when is_integer(val) do
    Integer.to_string(val) <> "%"
  end

  defp pct(_), do: "0%"

  defp format_float(val, decimals) when is_float(val) do
    :erlang.float_to_binary(val, decimals: decimals)
  end

  defp format_float(val, _decimals) when is_integer(val), do: Integer.to_string(val)
  defp format_float(_, _), do: "0"

  defp dim_color({r, g, b}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor)}
  end

  defp dim_color({r, g, b, a}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor), a}
  end
end
