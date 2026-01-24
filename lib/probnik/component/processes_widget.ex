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
  @row_height 32
  @header_height 40
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

    config = %{
      width: width,
      height: height,
      limit: limit,
      sort_by: sort_by,
      sort_dir: sort_dir
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

    Graph.build(font: :courier, font_size: 18)
    |> rect({config.width, config.height}, fill: c.bg)
    |> draw_header(c)
    |> draw_processes(processes, c, config)
  end

  defp draw_header(graph, c) do
    y = 25

    graph
    |> line({{0, @header_height}, {1400, @header_height}}, stroke: {2, c.border})
    |> text("PID", fill: c.secondary, translate: {10, y})
    |> text("Name / Initial Call", fill: c.secondary, translate: {10 + @col_widths.pid, y})
    |> text("MsgQ", fill: c.secondary, translate: {10 + @col_widths.pid + @col_widths.name, y})
    |> text("Memory", fill: c.secondary, translate: {10 + @col_widths.pid + @col_widths.name + @col_widths.msgq, y})
    |> text("Reds", fill: c.secondary, translate: {10 + @col_widths.pid + @col_widths.name + @col_widths.msgq + @col_widths.memory, y})
    |> text("Current Function", fill: c.secondary, translate: {10 + @col_widths.pid + @col_widths.name + @col_widths.msgq + @col_widths.memory + @col_widths.reds, y})
  end

  defp draw_processes(graph, processes, c, _config) do
    processes
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_process_row(g, proc, idx, c)
    end)
  end

  defp draw_process_row(graph, proc, idx, c) do
    y = @header_height + 25 + idx * @row_height
    x_offset = 10

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
    x2 = x1 + @col_widths.pid
    x3 = x2 + @col_widths.name
    x4 = x3 + @col_widths.msgq
    x5 = x4 + @col_widths.memory
    x6 = x5 + @col_widths.reds

    graph
    |> text(pid_str, fill: c.accent, translate: {x1, y})
    |> text(name_str, fill: text_color, translate: {x2, y})
    |> text(msgq_str, fill: msgq_color, translate: {x3, y})
    |> text(mem_str, fill: text_color, translate: {x4, y})
    |> text(reds_str, fill: text_color, translate: {x5, y})
    |> text(curr_str, fill: c.secondary, translate: {x6, y})
  end

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
