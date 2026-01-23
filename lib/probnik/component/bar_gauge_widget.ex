defmodule Probnik.Component.BarGaugeWidget do
  @moduledoc """
  Horizontal bar gauge widget for top 5 processes.
  Similar to oil temperature gauge but horizontal.
  Shows process name prominently with colored bar indicating value.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 1000
  @row_height 110
  @header_height 70
  @bar_segments 10

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 1600)
    height = Keyword.get(opts, :height, 600)
    # :memory or :message_queue_len
    attribute = Keyword.get(opts, :attribute, :memory)
    title = Keyword.get(opts, :title, "Top 5")

    config = %{
      width: width,
      height: height,
      attribute: attribute,
      title: title
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

    case :rpc.call(target, :recon, :proc_count, [attribute, 5], 5000) do
      {:badrpc, reason} ->
        IO.puts("RPC to #{target} failed: #{inspect(reason)}")
        []

      result when is_list(result) ->
        Enum.map(result, fn {pid, value, info} ->
          real_initial_call = :rpc.call(target, :proc_lib, :initial_call, [pid], 2000)
          %{pid: pid, value: value, name: extract_name(info, real_initial_call)}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp extract_name(info, real_initial_call) when is_list(info) do
    reg_name = Keyword.get(info, :registered_name)

    cond do
      is_atom(reg_name) and reg_name not in [nil, []] ->
        Atom.to_string(reg_name)

      is_tuple(real_initial_call) and tuple_size(real_initial_call) == 3 ->
        extract_mfa(real_initial_call)

      true ->
        "-"
    end
  end

  defp extract_name(_, _), do: "-"

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

    # Find max value for scaling bars
    max_val = procs |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end)

    Graph.build(font: :roboto, font_size: 36)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {3, c.border})
    |> draw_header(config, c)
    |> draw_rows(procs, max_val, config, c)
  end

  defp draw_header(graph, config, c) do
    graph
    |> text(config.title,
      fill: c.primary,
      font_size: 42,
      translate: {30, 50}
    )
    |> line({{0, @header_height}, {config.width, @header_height}}, stroke: {2, c.border})
  end

  defp draw_rows(graph, procs, max_val, config, c) do
    procs
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_row(g, proc, idx, max_val, config, c)
    end)
  end

  defp draw_row(graph, proc, idx, max_val, config, c) do
    y = @header_height + 15 + (idx - 1) * @row_height

    # Process name - BIG
    name_str = truncate(proc.name, 40)

    # Value
    value_str = format_value(proc.value, config.attribute)

    # Calculate bar fill ratio
    ratio = if max_val > 0, do: proc.value / max_val, else: 0

    # Bar dimensions
    bar_x = 30
    bar_y = y + 55
    bar_width = config.width - 60
    bar_height = 28
    segment_width = bar_width / @bar_segments
    segment_gap = 4

    # Color gradient based on ranking
    bar_colors = get_bar_colors(idx, c)

    graph
    # Name - large, prominent
    |> text(name_str,
      fill: c.primary,
      font_size: 44,
      translate: {bar_x, y + 40}
    )
    # Value - right aligned
    |> text(value_str,
      fill: c.secondary,
      font_size: 36,
      text_align: :right,
      translate: {config.width - 30, y + 40}
    )
    # Draw bar segments
    |> draw_bar_segments(bar_x, bar_y, segment_width, segment_gap, bar_height, ratio, bar_colors, c)
  end

  defp draw_bar_segments(graph, bar_x, bar_y, segment_width, gap, height, ratio, colors, c) do
    active_segments = trunc(ratio * @bar_segments)

    Enum.reduce(0..(@bar_segments - 1), graph, fn i, g ->
      x = bar_x + i * segment_width
      active = i < active_segments
      color = Enum.at(colors, i, c.secondary)

      fill =
        if active do
          color
        else
          # Dim version
          dim_color(color, 0.15)
        end

      g
      |> rrect({segment_width - gap, height, 4},
        fill: fill,
        translate: {x, bar_y}
      )
    end)
  end

  defp get_bar_colors(rank, c) do
    # Color gradient: green -> yellow -> red based on rank
    case rank do
      1 ->
        # Red gradient for top consumer
        List.duplicate(c.critical, 4) ++
          List.duplicate(c.warning, 3) ++
          List.duplicate(c.accent, 3)

      2 ->
        # Orange/yellow gradient
        List.duplicate(c.warning, 3) ++
          List.duplicate(c.accent, 4) ++
          List.duplicate(c.primary, 3)

      _ ->
        # Normal gradient
        List.duplicate(c.accent, 3) ++
          List.duplicate(c.primary, 4) ++
          List.duplicate(c.secondary, 3)
    end
  end

  defp dim_color({r, g, b}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor)}
  end

  defp dim_color({r, g, b, a}, factor) do
    {trunc(r * factor), trunc(g * factor), trunc(b * factor), a}
  end

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
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      bytes < 1024 * 1024 * 1024 -> "#{Float.round(bytes / 1024 / 1024, 1)} MB"
      true -> "#{Float.round(bytes / 1024 / 1024 / 1024, 2)} GB"
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
