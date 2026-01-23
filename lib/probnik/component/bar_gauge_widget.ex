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
  @row_height 100
  @header_height 70
  @bar_segments 30  # 3x more segments, skinnier marks

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

    result = case :rpc.call(target, :recon, :proc_count, [attribute, 5], 5000) do
      {:badrpc, reason} ->
        IO.puts("RPC to #{target} failed: #{inspect(reason)}, using local")
        fetch_local(attribute)

      result when is_list(result) and length(result) > 0 ->
        Enum.map(result, fn {pid, value, info} ->
          real_initial_call = :rpc.call(target, :proc_lib, :initial_call, [pid], 2000)
          %{pid: pid, value: value, name: extract_name(info, real_initial_call)}
        end)

      _ ->
        IO.puts("RPC returned empty, using local")
        fetch_local(attribute)
    end

    IO.puts("fetch_top5(#{attribute}): got #{length(result)} processes")
    result
  rescue
    e ->
      IO.puts("fetch_top5 error: #{inspect(e)}")
      fetch_local(attribute)
  end

  defp fetch_local(attribute) do
    :recon.proc_count(attribute, 5)
    |> Enum.map(fn {pid, value, info} ->
      real_initial_call = :proc_lib.initial_call(pid)
      %{pid: pid, value: value, name: extract_name(info, real_initial_call)}
    end)
  rescue
    _ -> []
  end

  defp extract_name(info, real_initial_call) when is_list(info) do
    reg_name = Keyword.get(info, :registered_name)

    cond do
      # Registered name is a proper atom (not nil, not empty list)
      is_atom(reg_name) and reg_name != nil ->
        Atom.to_string(reg_name)

      # Registered name is a list with an atom (e.g., [:Argument__1])
      is_list(reg_name) and length(reg_name) > 0 and is_atom(hd(reg_name)) ->
        reg_name |> hd() |> Atom.to_string()

      # Use real initial call from proc_lib
      is_tuple(real_initial_call) and tuple_size(real_initial_call) == 3 ->
        extract_mfa(real_initial_call)

      # Fallback to initial_call from info
      Keyword.has_key?(info, :initial_call) ->
        extract_mfa(Keyword.get(info, :initial_call))

      true ->
        "-"
    end
  rescue
    _ -> "-"
  end

  defp extract_name(_, _), do: "-"

  defp extract_mfa({m, f, a}) when is_atom(m) and is_atom(f) do
    module =
      m
      |> Atom.to_string()
      |> String.replace("Elixir.", "")

    "#{module}.#{f}/#{a}"
  end

  defp extract_mfa(other), do: inspect(other)

  # Intelligently shorten name to show rightmost distinct Module.Function/Arity
  defp shorten_name(name, max_len) when is_binary(name) do
    if String.length(name) <= max_len do
      name
    else
      # Try to show the most significant part (rightmost module + function)
      parts = String.split(name, ".")

      case parts do
        [single] ->
          # No dots, just truncate
          String.slice(single, 0, max_len - 2) <> ".."

        parts when length(parts) >= 2 ->
          # Get last two parts (Module.function/arity)
          [second_last, last] = Enum.take(parts, -2)
          short = "#{second_last}.#{last}"

          if String.length(short) <= max_len do
            short
          else
            # Still too long, truncate the module part
            available = max_len - String.length(last) - 3
            if available > 3 do
              String.slice(second_last, 0, available) <> "..#{last}"
            else
              String.slice(name, -max_len + 2, max_len - 2) <> ".."
            end
          end

        _ ->
          String.slice(name, 0, max_len - 2) <> ".."
      end
    end
  end

  defp shorten_name(nil, _max_len), do: "-"
  defp shorten_name(other, max_len) when not is_binary(other), do: shorten_name(inspect(other), max_len)

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

  defp draw_rows(graph, [], _max_val, config, c) do
    # Show message when no data
    graph
    |> text("No data - check node connection",
      fill: c.warning,
      font_size: 36,
      translate: {config.width / 2 - 200, config.height / 2}
    )
  end

  defp draw_rows(graph, procs, max_val, config, c) do
    procs
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_row(g, proc, idx, max_val, config, c)
    end)
  end

  defp draw_row(graph, proc, idx, max_val, config, c) do
    y = @header_height + 8 + (idx - 1) * @row_height
    row_inner_height = @row_height - 12

    # Layout: 40% name, 60% meter
    name_width = config.width * 0.4
    meter_x = name_width
    meter_width = config.width - meter_x - 20

    # Process name - intelligently shortened
    name_str = shorten_name(proc.name, 28)

    # Value
    value_str = format_value(proc.value, config.attribute)

    # Calculate bar fill ratio
    ratio = if max_val > 0, do: proc.value / max_val, else: 0

    # Bar dimensions - full height, skinny segments
    segment_width = meter_width / @bar_segments
    segment_gap = 2

    # Color gradient based on ranking
    bar_colors = get_bar_colors(idx, c)

    # Rank color
    rank_color =
      case idx do
        1 -> c.critical
        2 -> c.warning
        3 -> c.accent
        _ -> c.secondary
      end

    graph
    # Rank number
    |> text("#{idx}.",
      fill: rank_color,
      font_size: 36,
      translate: {15, y + row_inner_height / 2 + 12}
    )
    # Name - left side, large
    |> text(name_str,
      fill: c.primary,
      font_size: 40,
      translate: {55, y + row_inner_height / 2 + 12}
    )
    # Value - above meter
    |> text(value_str,
      fill: c.secondary,
      font_size: 28,
      text_align: :right,
      translate: {config.width - 25, y + 22}
    )
    # Draw bar segments - full height
    |> draw_bar_segments(meter_x, y + 4, segment_width, segment_gap, row_inner_height, ratio, bar_colors, c)
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
    # Color gradient for 30 segments based on rank
    case rank do
      1 ->
        # Red gradient for top consumer
        List.duplicate(c.critical, 12) ++
          List.duplicate(c.warning, 10) ++
          List.duplicate(c.accent, 8)

      2 ->
        # Orange/yellow gradient
        List.duplicate(c.warning, 10) ++
          List.duplicate(c.accent, 12) ++
          List.duplicate(c.primary, 8)

      _ ->
        # Normal gradient
        List.duplicate(c.accent, 10) ++
          List.duplicate(c.primary, 12) ++
          List.duplicate(c.secondary, 8)
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
