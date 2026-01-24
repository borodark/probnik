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
          extract_process_info(pid, value, info, real_initial_call)
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
      extract_process_info(pid, value, info, real_initial_call)
    end)
  rescue
    _ -> []
  end

  defp extract_process_info(pid, value, info, real_initial_call) do
    reg_name = extract_registered_name(info)
    {proc_type, module_fn} = extract_type_and_module(pid, info, real_initial_call)

    # Always display Module.Function/Arity
    %{
      pid: pid,
      value: value,
      type: proc_type,
      registered_name: reg_name,
      module_fn: module_fn,
      name: module_fn
    }
  end

  defp extract_registered_name(info) do
    reg_name = Keyword.get(info, :registered_name)

    cond do
      is_atom(reg_name) and reg_name != nil ->
        Atom.to_string(reg_name)

      is_list(reg_name) and length(reg_name) > 0 and is_atom(hd(reg_name)) ->
        reg_name |> hd() |> Atom.to_string()

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_type_and_module(pid, info, real_initial_call) do
    # Try multiple sources for the best name
    # 1. real_initial_call from proc_lib
    # 2. initial_call from info
    # 3. current_function from info
    # 4. registered_name
    # 5. PID as last resort

    result = try_extract_mfa(real_initial_call) ||
             try_extract_mfa(Keyword.get(info, :initial_call)) ||
             try_extract_mfa(Keyword.get(info, :current_function)) ||
             try_registered_name(info) ||
             {"PRC", format_pid(pid)}

    result
  rescue
    _ -> {"PRC", format_pid(pid)}
  end

  defp try_extract_mfa({mod, fun, arity}) when is_atom(mod) and is_atom(fun) do
    mod_str = mod |> Atom.to_string() |> String.replace("Elixir.", "")

    # Skip proc_lib and gen internal functions - not useful
    if mod_str in ["proc_lib", "gen", "gen_server", "supervisor"] and fun in [:init_p, :init_it, :loop, :init_p_do_apply] do
      nil
    else
      module_fn = "#{mod_str}.#{fun}/#{arity}"
      proc_type = detect_type(mod_str, fun)
      {proc_type, module_fn}
    end
  end

  defp try_extract_mfa(_), do: nil

  defp try_registered_name(info) do
    case Keyword.get(info, :registered_name) do
      name when is_atom(name) and name != nil ->
        name_str = Atom.to_string(name)
        {"REG", name_str}
      [name | _] when is_atom(name) ->
        {"REG", Atom.to_string(name)}
      _ ->
        nil
    end
  end

  defp format_pid(pid) when is_pid(pid) do
    pid |> inspect() |> String.replace(~r/[<>]/, "")
  end

  defp format_pid(_), do: "???"

  defp detect_type(mod_str, fun) do
    cond do
      String.contains?(mod_str, "Supervisor") -> "SUP"
      String.contains?(mod_str, "DynamicSupervisor") -> "DYN"
      String.contains?(mod_str, "GenServer") or fun == :init -> "GEN"
      String.contains?(mod_str, "GenEvent") -> "GEV"
      String.contains?(mod_str, "GenStateMachine") -> "GSM"
      String.contains?(mod_str, "Task") -> "TSK"
      String.contains?(mod_str, "Agent") -> "AGT"
      String.contains?(mod_str, "Phoenix") -> "PHX"
      String.contains?(mod_str, "Plug") -> "PLG"
      String.contains?(mod_str, "Ecto") -> "ECT"
      String.contains?(mod_str, "Logger") -> "LOG"
      String.contains?(mod_str, "Telemetry") -> "TEL"
      String.contains?(mod_str, "Finch") -> "FIN"
      String.contains?(mod_str, "Mint") -> "MNT"
      String.contains?(mod_str, "Bandit") -> "BAN"
      String.contains?(mod_str, "Registry") -> "REG"
      String.contains?(mod_str, "Cowboy") -> "COW"
      String.contains?(mod_str, "Ranch") -> "RAN"
      String.contains?(mod_str, "Pool") -> "POL"
      mod_str == "supervisor" -> "SUP"
      true -> "PRC"
    end
  end

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

    Graph.build(font: :roboto_mono, font_size: 36)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {3, c.border})
    |> draw_header(config, c)
    |> draw_rows(procs, max_val, config, c)
  end

  defp draw_header(graph, config, c) do
    # Column header for value (MB for memory, count for msgq)
    value_header = if config.attribute == :memory, do: "MB", else: "Cnt"

    # Layout: 5% type, 35% name, 10% value, 50% meter
    type_width = config.width * 0.05
    name_width = config.width * 0.35
    value_x = type_width + name_width + config.width * 0.1

    graph
    |> text(config.title,
      fill: c.primary,
      font: :roboto_mono,
      font_size: 42,
      translate: {type_width + 5, 50}
    )
    |> text(value_header,
      fill: c.secondary,
      font: :roboto_mono,
      font_size: 28,
      text_align: :right,
      translate: {value_x - 10, 50}
    )
    |> line({{0, @header_height}, {config.width, @header_height}}, stroke: {2, c.border})
  end

  defp draw_rows(graph, [], _max_val, config, c) do
    # Show message when no data
    graph
    |> text("No data - check node connection",
      fill: c.warning,
      font: :roboto_mono,
      font_size: 36,
      translate: {config.width / 2 - 250, config.height / 2}
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

    # Layout: 5% type, 35% name, 10% value, 50% meter
    type_width = config.width * 0.05
    name_width = config.width * 0.35
    value_x = type_width + name_width
    value_width = config.width * 0.1
    meter_x = value_x + value_width
    meter_width = config.width - meter_x - 15

    # Process type (GS, Sup, Task, etc.)
    type_str = Map.get(proc, :type, "Proc")

    # Process name - show registered name or module.function
    name_str = shorten_name(proc.name, 26)

    # Value - GB with 2 decimals for memory
    value_str = format_value_display(proc.value, config.attribute)

    # Calculate bar fill ratio
    ratio = if max_val > 0, do: proc.value / max_val, else: 0

    # Bar dimensions - full height, skinny segments
    segment_width = meter_width / @bar_segments
    segment_gap = 2

    # Color gradient based on ranking
    bar_colors = get_bar_colors(idx, c)

    # Type color based on process type
    type_color = get_type_color(type_str, c)

    graph
    # Type - 5% left
    |> text(type_str,
      fill: type_color,
      font: :roboto_mono,
      font_size: 28,
      translate: {8, y + row_inner_height / 2 + 10}
    )
    # Name - after type
    |> text(name_str,
      fill: c.primary,
      font: :roboto_mono,
      font_size: 36,
      translate: {type_width + 5, y + row_inner_height / 2 + 12}
    )
    # Value - in the 10% area before meter
    |> text(value_str,
      fill: c.primary,
      font: :roboto_mono,
      font_size: 32,
      text_align: :right,
      translate: {meter_x - 10, y + row_inner_height / 2 + 10}
    )
    # Draw bar segments - full height
    |> draw_bar_segments(meter_x, y + 4, segment_width, segment_gap, row_inner_height, ratio, bar_colors, c)
  end

  defp get_type_color(type, c) do
    case type do
      "GEN" -> c.accent      # GenServer
      "SUP" -> c.warning     # Supervisor
      "DYN" -> c.warning     # DynamicSupervisor
      "TSK" -> c.primary     # Task
      "PHX" -> c.critical    # Phoenix
      "ECT" -> c.accent      # Ecto
      "LOG" -> c.secondary   # Logger
      "TEL" -> c.secondary   # Telemetry
      "FIN" -> c.accent      # Finch
      "BAN" -> c.critical    # Bandit
      "REG" -> c.primary     # Registry
      _ -> c.secondary
    end
  end

  # Format value for display in the value column
  defp format_value_display(bytes, :memory) do
    mb = bytes / 1024 / 1024
    :erlang.float_to_binary(mb, decimals: 2)
  end

  defp format_value_display(count, :message_queue_len) do
    Integer.to_string(count)
  end

  defp format_value_display(value, _), do: inspect(value)

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
end
