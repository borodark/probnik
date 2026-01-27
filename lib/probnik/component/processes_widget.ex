defmodule Probnik.Component.ProcessesWidget do
  @moduledoc """
  Displays a list of Erlang/Elixir processes with key metrics.
  Similar to Phoenix LiveDashboard's processes view.

  Columns: PID, Name, MsgQ, Memory, Reductions, Current Function
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 1000

  # Layout
  @base_width 1400
  @base_height 800
  @col_widths %{
    pid: 140,
    name: 400,
    msgq: 100,
    memory: 120,
    reds: 140,
    current: 500
  }

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 1400)
    height = Keyword.get(opts, :height, 800)
    limit = Keyword.get(opts, :limit, 20)
    sort_by = Keyword.get(opts, :sort_by, :message_queue_len)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    sx = width / @base_width
    sy = height / @base_height
    s = min(sx, sy)
    header_h = max(12, round(40 * sy))
    config = %{
      width: width,
      height: height,
      limit: limit,
      sort_by: sort_by,
      sort_dir: sort_dir,
      sx: sx,
      sy: sy,
      s: s,
      header_height: header_h
    }

    processes = fetch_processes(config)
    graph = build_graph(processes, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(config: config, processes: processes)
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl GenServer
  def handle_info(:refresh, scene) do
    %{config: config} = scene.assigns

    processes = fetch_processes(config)
    graph = build_graph(processes, config)

    Process.send_after(self(), :refresh, @update_interval)

    scene
    |> assign(processes: processes)
    |> push_graph(graph)
    |> then(&{:noreply, &1})
  end

  defp fetch_processes(config) do
    Process.list()
    |> Enum.map(&get_process_info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, config.sort_by), config.sort_dir)
    |> Enum.take(config.limit)
  end

  defp get_process_info(pid) do
    case Process.info(pid, [
           :registered_name,
           :message_queue_len,
           :memory,
           :reductions,
           :current_function,
           :initial_call
         ]) do
      nil ->
        nil

      info ->
        %{
          pid: pid,
          name: format_name(info[:registered_name], info[:initial_call]),
          message_queue_len: info[:message_queue_len] || 0,
          memory: info[:memory] || 0,
          reductions: info[:reductions] || 0,
          current_function: format_mfa(info[:current_function])
        }
    end
  end

  defp format_name([], initial_call), do: format_mfa(initial_call)
  defp format_name(name, _) when is_atom(name), do: Atom.to_string(name)
  defp format_name(_, initial_call), do: format_mfa(initial_call)

  defp format_mfa(nil), do: "-"
  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(other), do: inspect(other)

  defp build_graph(processes, config) do
    c = ColorScheme.current()

    Graph.build(font: :courier, font_size: max(10, round(18 * config.s)))
    |> rect({config.width, config.height}, fill: c.bg)
    |> draw_processes(processes, c, config)
    |> draw_watermark(config, c)
  end

  defp draw_process_row(graph, proc, idx, c, config) do
    sx = config.sx
    sy = config.sy
    top_pad = 8 * sy
    row_height = (config.height - top_pad * 2) / max(config.limit, 1)
    y = top_pad + idx * row_height
    x_offset = 10 * sx
    col_widths = scale_cols(sx)

    # Highlight rows with message queue > 0
    {text_color, msgq_color} =
      cond do
        proc.message_queue_len > 100 -> {c.critical, c.critical}
        proc.message_queue_len > 10 -> {c.warning, c.warning}
        proc.message_queue_len > 0 -> {c.primary, c.accent}
        true -> {c.primary, c.primary}
      end

    pid_str = inspect(proc.pid)
    name_str = truncate(proc.name, 35)
    msgq_str = Integer.to_string(proc.message_queue_len)
    mem_str = format_bytes(proc.memory)
    reds_str = format_number(proc.reductions)
    curr_str = truncate(proc.current_function, 45)

    x1 = x_offset
    x2 = x1 + col_widths.pid
    x3 = x2 + col_widths.name
    x4 = x3 + col_widths.msgq
    x5 = x4 + col_widths.memory
    x6 = x5 + col_widths.reds

    graph
    |> text(pid_str, fill: c.accent, translate: {x1, y})
    |> text(name_str, fill: text_color, translate: {x2, y})
    |> text(msgq_str, fill: msgq_color, translate: {x3, y})
    |> text(mem_str, fill: text_color, translate: {x4, y})
    |> text(reds_str, fill: text_color, translate: {x5, y})
    |> text(curr_str, fill: c.secondary, translate: {x6, y})
  end

  defp draw_processes(graph, processes, c, config) do
    processes
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_process_row(g, proc, idx, c, config)
    end)
  end

  defp scale_cols(sx) do
    %{
      pid: @col_widths.pid * sx,
      name: @col_widths.name * sx,
      msgq: @col_widths.msgq * sx,
      memory: @col_widths.memory * sx,
      reds: @col_widths.reds * sx,
      current: @col_widths.current * sx
    }
  end

  defp draw_watermark(graph, config, c) do
    area_w = config.width * 0.4
    area_h = config.height * 0.4
    font_size = max(12, round(min(area_w, area_h) * 0.35))
    x = config.width - 12 * config.s
    y = config.height - 12 * config.s

    graph
    |> text("PROCS",
      fill: with_alpha(c.secondary, 80),
      font: :courier_bold,
      font_size: font_size,
      text_align: :right,
      translate: {x, y}
    )
  end

  defp with_alpha({r, g, b}, a), do: {r, g, b, a}
  defp with_alpha({r, g, b, _}, a), do: {r, g, b, a}

  defp truncate(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 2) <> ".."
    else
      str
    end
  end

  defp truncate(other, max_len), do: truncate(inspect(other), max_len)

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"

  defp format_number(n) when n < 1000, do: Integer.to_string(n)
  defp format_number(n) when n < 1_000_000, do: "#{Float.round(n / 1000, 1)}K"
  defp format_number(n), do: "#{Float.round(n / 1_000_000, 1)}M"
end
