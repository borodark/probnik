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
  @info_height 0

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
    pressure = pressure_score(data, usage_stats(data.schedulers) |> elem(0))
    graph = build_graph(data, config, pressure, 0.0)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(config: config, data: data, pressure: pressure, prev_runq: data.run_queue_total, runq_rate: 0.0)
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl GenServer
  def handle_info(:refresh, scene) do
    %{config: config} = scene.assigns

    data = fetch_data()
    raw = pressure_score(data, usage_stats(data.schedulers) |> elem(0))
    pressure = smooth_pressure(raw, scene.assigns[:pressure])
    runq_rate = smooth_pressure(runq_rate(data, scene.assigns[:prev_runq]), scene.assigns[:runq_rate])
    graph = build_graph(data, config, pressure, runq_rate)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(data: data, pressure: pressure, prev_runq: data.run_queue_total, runq_rate: runq_rate)
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

  defp build_graph(data, config, pressure, runq_rate) do
    c = ColorScheme.current()
    schedulers = data.schedulers

    {avg_usage, _max_usage} = usage_stats(schedulers)
    {avg_rq, max_rq, min_rq} = run_queue_stats(schedulers, data.run_queue_total)

    Graph.build(font: :courier, font_size: 24)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> draw_header(config, c)
    |> draw_info(data, config, avg_usage, avg_rq, max_rq, min_rq, pressure, runq_rate, c)
    |> draw_rows([], config, c)
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

  defp draw_info(graph, data, config, avg_usage, avg_rq, max_rq, min_rq, pressure, runq_rate, c) do
    rq_skew = max_rq - min_rq

    graph
    |> draw_tape_gauge(data, avg_usage, avg_rq, rq_skew, pressure, runq_rate, config, c)
  end

  defp pressure_score(data, avg_usage) do
    schedulers = max(data.schedulers_online || length(data.schedulers), 1)
    rq_norm = min(data.run_queue_total / (schedulers * 2), 1.0)
    score = avg_usage * 0.7 + rq_norm * 0.3
    min(max(score, 0.0), 1.0)
  end

  defp runq_rate(data, prev_runq) when is_integer(prev_runq) do
    interval_s = @update_interval / 1000
    (data.run_queue_total - prev_runq) / interval_s
  end

  defp runq_rate(_data, _prev), do: 0.0

  defp smooth_pressure(raw, nil), do: raw
  defp smooth_pressure(raw, prev) when is_number(prev) do
    alpha = 0.25
    alpha * raw + (1.0 - alpha) * prev
  end

  defp draw_tape_gauge(graph, data, avg_usage, avg_rq, rq_skew, pressure, runq_rate, config, c) do
    # Horizontal VU-style meter with needle
    x = 20
    y = @header_height + 6
    height = config.height - y - 6
    width = config.width - 40
    ratio = min(max(pressure, 0.0), 1.0)
    needle_x = x + width * ratio
    rq_ratio = min(data.run_queue_total / max(data.schedulers_online, 1) / 4, 1.0)
    usage_ratio = min(max(avg_usage, 0.0), 1.0)

    graph
    |> draw_pressure_fill(x, y, width, height, ratio)
    |> draw_vsi_texts(x + 10, y, 140, height, runq_rate, c)
    |> text("RunQ #{data.run_queue_total}",
      fill: pressure_text_color(rq_ratio, c),
      font: :courier,
      font_size: 26,
      translate: {x + 12, y + 34}
    )
    |> text("avg #{format_float(avg_rq, 1)}",
      fill: pressure_text_color(rq_ratio, c),
      font: :courier,
      font_size: 22,
      translate: {x + 12, y + 62}
    )
    |> text("skew #{rq_skew}",
      fill: pressure_text_color(rq_ratio, c),
      font: :courier,
      font_size: 22,
      translate: {x + 12, y + 88}
    )
    |> text("util #{pct(usage_ratio)}",
      fill: pressure_text_color(rq_ratio, c),
      font: :courier,
      font_size: 22,
      translate: {x + 12, y + 114}
    )
    |> line({{needle_x, y - 6}, {needle_x, y + height + 6}}, stroke: {3, c.needle})
  end

  defp draw_pressure_fill(graph, x, y, width, height, ratio) do
    fill_w = width * min(max(ratio, 0.0), 1.0)

    segments = [
      {0.25, {0, 0, 0}, {0, 180, 0}},
      {0.35, {0, 180, 0}, {255, 180, 0}},
      {0.25, {255, 180, 0}, {255, 100, 0}},
      {0.15, {255, 100, 0}, {135, 0, 0}}
    ]

    {graph, _} =
      Enum.reduce(segments, {graph, 0.0}, fn {seg_ratio, c1, c2}, {g, offset} ->
        seg_w_full = width * seg_ratio
        remaining = fill_w - offset
        seg_w = min(seg_w_full, max(remaining, 0.0))

        if seg_w > 0.0 do
          t = if seg_w_full == 0.0, do: 0.0, else: seg_w / seg_w_full
          c2p = lerp_color(c1, c2, t)

          g =
            g
            |> rect({seg_w, height},
              fill: {:linear, {0, 0, seg_w, 0, c1, c2p}},
              translate: {x + offset, y}
            )

          {g, offset + seg_w}
        else
          {g, offset}
        end
      end)

    graph
  end

  defp draw_vsi_texts(graph, x, y, width, height, rate, c) do
    half = height / 2
    font_size = trunc(half * 0.7)
    pos_color = if rate > 0, do: c.critical, else: c.secondary
    neg_color = if rate < 0, do: c.negative, else: c.secondary
    pos_val = if rate > 0, do: "+#{round(rate)}", else: "+0"
    neg_val = if rate < 0, do: "-#{round(abs(rate))}", else: "-0"

    graph
    |> text(pos_val,
      fill: pos_color,
      font: :courier_bold,
      font_size: font_size,
      text_align: :center,
      translate: {x + width / 2, y + half / 2 + font_size / 3}
    )
    |> text(neg_val,
      fill: neg_color,
      font: :courier_bold,
      font_size: font_size,
      text_align: :center,
      translate: {x + width / 2, y + half + half / 2 + font_size / 3}
    )
  end

  defp lerp_color({r1, g1, b1}, {r2, g2, b2}, t) do
    {
      trunc(r1 + (r2 - r1) * t),
      trunc(g1 + (g2 - g1) * t),
      trunc(b1 + (b2 - b1) * t)
    }
  end

  defp pressure_text_color(ratio, c) do
    base = pressure_fill_color(ratio)
    lerp_color(base, c.accent, 0.35)
  end

  defp pressure_fill_color(ratio) do
    t = min(max(ratio, 0.0), 1.0)

    cond do
      t <= 0.25 ->
        # black -> green
        k = t / 0.25
        {0, trunc(180 * k), 0}

      t <= 0.6 ->
        # green -> yellow
        k = (t - 0.25) / 0.35
        {trunc(255 * k), 180, 0}

      t <= 0.85 ->
        # yellow -> orange
        k = (t - 0.6) / 0.25
        {255, trunc(180 - 80 * k), 0}

      true ->
        # orange -> dark red
        k = (t - 0.85) / 0.15
        {trunc(255 - 120 * k), 0, 0}
    end
  end


  defp draw_rows(graph, _schedulers, _config, _c), do: graph

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

end
