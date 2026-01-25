defmodule Probnik.Component.SchedulerPressureWidget do
  @moduledoc """
  Scheduler pressure widget.
  Displays:
  - A tape-style pressure gauge (combo of avg scheduler util + normalized run queue).
  - Run-queue totals/avg/skew and avg util text.
  - Run-queue trend (Δ runq/sec) as large + / - values and a mini VSI dial.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives


  @update_interval 2000
  @header_height 60
  @vsi_max_rate 20
  @vsi_sweep :math.pi() * 5 / 6

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
    graph = build_graph(data, config, pressure, 0.0, 0.0)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(
      config: config,
      data: data,
      pressure: pressure,
      prev_runq: data.run_queue_total,
      runq_rate: 0.0,
      runq_sign: 0,
      glow_until: 0
    )
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl GenServer
  def handle_info(:refresh, scene) do
    %{config: config} = scene.assigns

    data = fetch_data()
    raw = pressure_score(data, usage_stats(data.schedulers) |> elem(0))
    pressure = smooth_pressure(raw, scene.assigns[:pressure])
    rate_raw = runq_rate(data, scene.assigns[:prev_runq])
    runq_rate = smooth_pressure(rate_raw, scene.assigns[:runq_rate])
    sign = sign_of(rate_raw)
    prev_sign = scene.assigns[:runq_sign] || 0
    now_ms = now_ms()
    glow_until =
      if prev_sign != 0 and sign != 0 and prev_sign != sign do
        now_ms + 1400
      else
        scene.assigns[:glow_until] || 0
      end

    glow_intensity = glow_intensity(now_ms, glow_until)
    graph = build_graph(data, config, pressure, runq_rate, glow_intensity)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(
      data: data,
      pressure: pressure,
      prev_runq: data.run_queue_total,
      runq_rate: runq_rate,
      runq_sign: sign,
      glow_until: glow_until
    )
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

  defp build_graph(data, config, pressure, runq_rate, glow_intensity) do
    c = ColorScheme.current()
    schedulers = data.schedulers

    {avg_usage, _max_usage} = usage_stats(schedulers)
    {avg_rq, max_rq, min_rq} = run_queue_stats(schedulers, data.run_queue_total)

    Graph.build(font: :courier, font_size: 24)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> draw_header(config, c)
    |> draw_info(data, config, avg_usage, avg_rq, max_rq, min_rq, pressure, runq_rate, glow_intensity, c)
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

  defp draw_info(graph, data, config, avg_usage, avg_rq, max_rq, min_rq, pressure, runq_rate, glow_intensity, c) do
    rq_skew = max_rq - min_rq

    graph
    |> draw_tape_gauge(data, avg_usage, avg_rq, rq_skew, pressure, runq_rate, glow_intensity, config, c)
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

  defp sign_of(v) when is_number(v) and v > 0, do: 1
  defp sign_of(v) when is_number(v) and v < 0, do: -1
  defp sign_of(_), do: 0

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp glow_intensity(now_ms, glow_until) when is_integer(glow_until) do
    remaining = glow_until - now_ms
    if remaining > 0 do
      ease(min(remaining / 1400, 1.0))
    else
      0.0
    end
  end

  defp glow_intensity(_, _), do: 0.0

  defp smooth_pressure(raw, nil), do: raw
  defp smooth_pressure(raw, prev) when is_number(prev) do
    alpha = 0.25
    alpha * raw + (1.0 - alpha) * prev
  end

  defp draw_tape_gauge(graph, data, avg_usage, avg_rq, rq_skew, pressure, runq_rate, glow_intensity, config, c) do
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
    #|> draw_vsi_texts(x + 10, y, 140, height, runq_rate, c)
    |> draw_vsi_circle(x + 320, y + height / 2, 200, runq_rate, glow_intensity, c)
    |> text("RunQ #{data.run_queue_total}",
      fill: runq_glow_color(rq_ratio),
      font: :courier,
      font_size: 48,
      translate: {x + 12, y + 32}
    )
    |> text("avg #{format_float(avg_rq, 1)}",
      fill: runq_glow_color(rq_ratio),
      font: :courier,
      font_size: 48,
      translate: {x + 12, y + 78}
    )
    |> text("skew #{rq_skew}",
      fill: runq_glow_color(rq_ratio),
      font: :courier,
      font_size: 48,
      translate: {x + 12, y + 460}
    )
    |> text("util #{pct(usage_ratio)}",
      fill: runq_glow_color(rq_ratio),
      font: :courier,
      font_size: 48,
      translate: {x + 12, y + 500}
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

  #defp draw_vsi_texts(graph, x, y, width, height, rate, c) do
  #  half = height / 2
  #  font_size = trunc(half * 0.24)
  #  pos_val = if rate > 0, do: "+#{round(rate)}", else: ""
  #  neg_val = if rate < 0, do: "-#{round(abs(rate))}", else: ""
  #  pos_color = glow_color(rate, :pos, c)
  #  neg_color = glow_color(rate, :neg, c)#

  #  graph
  #  |> maybe_text(pos_val, pos_color, font_size, x + width / 2, y + half / 2 + font_size / 3)
  #  |> maybe_text(neg_val, neg_color, font_size, x + width / 2, y + half + half / 2 + font_size / 3)
  #end

  defp draw_vsi_circle(graph, cx, cy, radius, rate, glow_intensity, c) do
    clamped = max(-@vsi_max_rate, min(@vsi_max_rate, rate))
    direction = if clamped >= 0, do: :up, else: :down
    angle = vsi_value_to_angle(abs(clamped), direction)

    needle_len = radius - 6
    x2 = cx + :math.cos(angle) * needle_len
    y2 = cy + :math.sin(angle) * needle_len

    graph
    |> draw_vsi_afterglow(cx, cy, radius, glow_intensity)
    |> circle(radius, stroke: {2, c.tick}, translate: {cx, cy})
    |> draw_vsi_ticks(cx, cy, radius, c)
    |> line({{cx, cy}, {x2, y2}}, stroke: {3, c.needle}, cap: :round)
    |> circle(3, fill: c.needle, translate: {cx, cy})
    |> text(vsi_signed_value(rate),
      fill: {0, 0, 0},
      font: :roboto,
      font_size: 64,
      text_align: :center,
      translate: {cx, cy - radius * 0.3}
    )
    |> text("Δ runq/sec",
      fill: {0, 0, 0},
      font: :courier_bold,
      font_size: 32,
      text_align: :center,
      translate: {cx, cy + radius * 0.45}
    )
    |> draw_vsi_chevrons(cx, cy, radius, rate, c)
  end

  defp vsi_signed_value(rate) when is_number(rate) do
    value = round(rate)
    if value > 0, do: "+#{value}", else: Integer.to_string(value)
  end

  defp draw_vsi_afterglow(graph, _cx, _cy, _radius, glow) when glow <= 0.0, do: graph

  defp draw_vsi_afterglow(graph, cx, cy, radius, glow) do
    color = warm_glow(0.6)
    alpha1 = trunc(40 + glow * 140)
    alpha2 = trunc(20 + glow * 90)
    alpha3 = trunc(10 + glow * 60)

    graph
    |> circle(radius + 10, stroke: {2, with_alpha(color, alpha1)}, translate: {cx, cy})
    |> circle(radius + 18, stroke: {2, with_alpha(color, alpha2)}, translate: {cx, cy})
    |> circle(radius + 26, stroke: {2, with_alpha(color, alpha3)}, translate: {cx, cy})
  end

  defp draw_vsi_chevrons(graph, cx, cy, radius, rate, c) do
    t = min(abs(rate) / @vsi_max_rate, 1.0)
    up_color = if rate > 0, do: warm_glow(t), else: c.tick
    down_color = if rate < 0, do: warm_glow(t), else: c.tick
    base_alpha = if t < 0.05, do: 40, else: trunc(40 + t * 215)
    phase = rem(now_ms(), 1000) / 1000

    up_chevrons = [
      {cy - radius + 28, 9},
      {cy - radius + 8, 11},
      {cy - radius - 12, 13}
    ]

    down_chevrons = [
      {cy + radius - 28, 9},
      {cy + radius - 8, 11},
      {cy + radius + 12, 13}
    ]

    graph
    |> draw_animated_chevrons(cx, up_chevrons, :up, rate, up_color, base_alpha, phase)
    |> draw_animated_chevrons(cx, down_chevrons, :down, rate, down_color, base_alpha, phase)
  end

  defp draw_animated_chevrons(graph, cx, chevrons, dir, rate, color, base_alpha, phase) do
    count = length(chevrons)
    active_idx = trunc(phase * count) |> min(count - 1) |> max(0)

    Enum.with_index(chevrons, 0)
    |> Enum.reduce(graph, fn {{cy, size}, idx}, g ->
      active = (dir == :up and rate >= 0) or (dir == :down and rate < 0)
      dist = abs(idx - active_idx)
      wave =
        cond do
          dist == 0 -> 1.0
          dist == 1 -> 0.6
          dist == 2 -> 0.3
          true -> 0.15
        end

      alpha =
        if active do
          trunc(base_alpha * wave)
        else
          trunc(base_alpha * 0.15)
        end

      g
      |> draw_chevron(cx, cy, size, dir, with_alpha(color, alpha))
    end)
  end

  defp with_alpha({r, g, b}, a), do: {r, g, b, a}
  defp with_alpha({r, g, b, _}, a), do: {r, g, b, a}

  defp draw_chevron(graph, cx, cy, size, :up, color) do
    graph
    |> line({{cx - size, cy + size}, {cx, cy}}, stroke: {5, color}, cap: :round)
    |> line({{cx, cy}, {cx + size, cy + size}}, stroke: {5, color}, cap: :round)
  end

  defp draw_chevron(graph, cx, cy, size, :down, color) do
    graph
    |> line({{cx - size, cy - size}, {cx, cy}}, stroke: {5, color}, cap: :round)
    |> line({{cx, cy}, {cx + size, cy - size}}, stroke: {5, color}, cap: :round)
  end

  defp draw_vsi_ticks(graph, cx, cy, radius, c) do
    values = [0, 10, 20]

    Enum.reduce(values, graph, fn v, g ->
      g
      |> draw_vsi_tick(cx, cy, radius, v, :up, c)
      |> draw_vsi_tick(cx, cy, radius, v, :down, c)
    end)
  end

  defp draw_vsi_tick(graph, cx, cy, radius, value, direction, c) do
    angle = vsi_value_to_angle(value, direction)
    inner = radius - 6
    outer = radius

    x1 = cx + :math.cos(angle) * inner
    y1 = cy + :math.sin(angle) * inner
    x2 = cx + :math.cos(angle) * outer
    y2 = cy + :math.sin(angle) * outer

    graph
    |> line({{x1, y1}, {x2, y2}}, stroke: {2, c.tick}, cap: :round)
  end

  defp vsi_value_to_angle(value, :up) do
    fraction = value / @vsi_max_rate
    :math.pi() + fraction * @vsi_sweep
  end

  defp vsi_value_to_angle(value, :down) do
    fraction = value / @vsi_max_rate
    :math.pi() - fraction * @vsi_sweep
  end


  defp warm_glow(t) do
    # bright orange -> dark red
    lerp_color({255, 140, 0}, {120, 0, 0}, t)
  end

  defp ease(t) do
    # Smoothstep for gentle color transitions
    t2 = min(max(t, 0.0), 1.0)
    t2 * t2 * (3 - 2 * t2)
  end

  defp lerp_color({r1, g1, b1}, {r2, g2, b2}, t) do
    {
      trunc(r1 + (r2 - r1) * t),
      trunc(g1 + (g2 - g1) * t),
      trunc(b1 + (b2 - b1) * t)
    }
  end

  defp runq_glow_color(ratio) do
    t = min(max(ratio, 0.0), 1.0)

    cond do
      t <= 0.2 ->
        lerp_color({0, 0, 0}, {140, 60, 0}, t / 0.2)

      t <= 0.4 ->
        lerp_color({140, 60, 0}, {220, 120, 0}, (t - 0.2) / 0.2)

      t <= 0.6 ->
        lerp_color({220, 120, 0}, {180, 140, 0}, (t - 0.4) / 0.2)

      t <= 0.8 ->
        lerp_color({180, 140, 0}, {255, 210, 0}, (t - 0.6) / 0.2)

      true ->
        lerp_color({255, 210, 0}, {255, 0, 0}, (t - 0.8) / 0.2)
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
