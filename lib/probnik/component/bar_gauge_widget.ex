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


  @update_interval 250
  @bar_segments 30  # 3x more segments, skinnier marks
  @base_width 1600
  @base_height 600

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

    scale = min(width / @base_width, height / @base_height)
    config = %{
      width: width,
      height: height,
      attribute: attribute,
      title: title,
      scale: scale
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

    result =
      if remote_target?(target) do
        case :rpc.call(target, :recon, :proc_count, [attribute, 5], 5000) do
          {:badrpc, _reason} ->
            fetch_local(attribute)

          result when is_list(result) and length(result) > 0 ->
            Enum.map(result, fn {pid, value, info} ->
              real_initial_call = :rpc.call(target, :proc_lib, :initial_call, [pid], 2000)
              extract_process_info(target, pid, value, info, real_initial_call)
            end)

          _ ->
            fetch_local(attribute)
        end
      else
        fetch_local(attribute)
      end

    result
  rescue
    _e ->
      fetch_local(attribute)
  end

  defp fetch_local(attribute) do
    :recon.proc_count(attribute, 5)
    |> Enum.map(fn {pid, value, info} ->
      real_initial_call = :proc_lib.initial_call(pid)
      extract_process_info(node(), pid, value, info, real_initial_call)
    end)
  rescue
    _ -> []
  end

  defp remote_target?(target) do
    target != Node.self() and Node.alive?() and Enum.member?(Node.list(), target)
  end

  # =============================================================================
  # Process Info Extraction - Ergonomic Labels
  # =============================================================================

  defp extract_process_info(target, pid, value, info, real_initial_call) do
    # Gather all available process metadata
    reg_name = extract_registered_name(info)
    dict = get_process_dictionary(target, pid)
    ancestors = get_ancestors(dict)
    initial_call = get_initial_call(real_initial_call, info, dict)

    # Build ergonomic label using heuristics
    {category, label} = build_ergonomic_label(target, pid, reg_name, initial_call, ancestors, dict)

    %{
      pid: pid,
      value: value,
      type: category,
      registered_name: reg_name,
      module_fn: format_mfa(initial_call),
      name: label
    }
  end

  # Get process dictionary (contains $ancestors, $initial_call, etc.)
  defp get_process_dictionary(target, pid) do
    case safe_rpc(target, :erlang, :process_info, [pid, :dictionary]) do
      {:dictionary, dict} when is_list(dict) -> dict
      _ -> []
    end
  end

  # Extract $ancestors from process dictionary
  defp get_ancestors(dict) do
    case Keyword.get(dict, :"$ancestors") do
      ancestors when is_list(ancestors) -> ancestors
      _ -> []
    end
  end

  # Get initial call from multiple sources
  defp get_initial_call(real_initial_call, info, dict) do
    # Priority: proc_lib initial_call > $initial_call > process_info initial_call
    candidates = [
      real_initial_call,
      Keyword.get(dict, :"$initial_call"),
      Keyword.get(info, :initial_call)
    ]

    Enum.find_value(candidates, fn
      {m, f, a} when is_atom(m) and is_atom(f) ->
        if system_init?(m, f), do: nil, else: {m, f, a}
      _ ->
        nil
    end)
  end

  defp system_init?(mod, fun) do
    mod in [:proc_lib, :gen, :gen_server, :supervisor, :gen_statem, :gen_event] and
      fun in [:init, :init_p, :init_it, :loop, :init_p_do_apply]
  end

  defp extract_registered_name(info) do
    case Keyword.get(info, :registered_name) do
      name when is_atom(name) and name != nil ->
        name |> Atom.to_string() |> String.replace("Elixir.", "")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # =============================================================================
  # Ergonomic Label Building - Main Logic
  # =============================================================================

  defp build_ergonomic_label(target, _pid, reg_name, initial_call, ancestors, dict) do
    cond do
      # 1. Check for well-known patterns first
      label = detect_well_known_pattern(target, reg_name, initial_call, ancestors, dict) ->
        label

      # 2. Registered name - often the most meaningful
      reg_name != nil ->
        {categorize_registered_name(reg_name), shorten_module_name(reg_name)}

      # 3. Pool worker detection
      pool_info = detect_pool_worker(target, ancestors, initial_call) ->
        pool_info

      # 4. Use initial_call with ancestor context
      initial_call != nil ->
        build_label_from_mfa(target, initial_call, ancestors)

      # 5. Fallback - try to find any meaningful ancestor
      true ->
        case find_meaningful_ancestor(target, ancestors) do
          nil -> {"?", "unknown"}
          ancestor_name -> {"Worker", "#{shorten_module_name(ancestor_name)}:child"}
        end
    end
  end

  # =============================================================================
  # Well-Known Pattern Detection
  # =============================================================================

  defp detect_well_known_pattern(target, reg_name, initial_call, ancestors, _dict) do
    mfa_str = format_mfa(initial_call)

    cond do
      # Phoenix LiveView
      String.contains?(mfa_str || "", "LiveView") or
      ancestor_contains?(target, ancestors, "LiveView") ->
        module_name = extract_module_name(initial_call) || "View"
        {"LiveView", shorten_module_name(module_name)}

      # Phoenix Channel
      String.contains?(mfa_str || "", "Channel") or
      ancestor_contains?(target, ancestors, "Channel") ->
        module_name = extract_module_name(initial_call) || "Channel"
        {"Channel", shorten_module_name(module_name)}

      # Phoenix Endpoint / Cowboy / Bandit request
      String.contains?(mfa_str || "", "Plug.Cowboy") or
      String.contains?(mfa_str || "", "Bandit") or
      ancestor_contains?(target, ancestors, "Endpoint") ->
        {"HTTP", "Request"}

      # Ecto Repo / DBConnection
      String.contains?(mfa_str || "", "DBConnection") or
      String.contains?(mfa_str || "", "Postgrex") or
      String.contains?(mfa_str || "", "MyXQL") or
      ancestor_contains?(target, ancestors, "Repo") ->
        repo_name = find_repo_name(target, ancestors) || "DB"
        {"DB", shorten_module_name(repo_name)}

      # Oban job worker
      String.contains?(mfa_str || "", "Oban") ->
        job_name = extract_module_name(initial_call) || "Job"
        {"Job", shorten_module_name(job_name)}

      # Task
      String.contains?(mfa_str || "", "Task") ->
        task_fn = extract_task_function(initial_call)
        {"Task", task_fn || "async"}

      # GenStage / Broadway
      String.contains?(mfa_str || "", "GenStage") or
      String.contains?(mfa_str || "", "Broadway") ->
        stage_name = extract_module_name(initial_call) || "Stage"
        {"Stage", shorten_module_name(stage_name)}

      # Supervisor
      is_supervisor?(mfa_str, reg_name) ->
        sup_name = reg_name || extract_module_name(initial_call) || "Supervisor"
        {"Sup", shorten_module_name(sup_name)}

      # Registry
      String.contains?(mfa_str || "", "Registry") ->
        {"Registry", shorten_module_name(reg_name || "Registry")}

      # GenServer with registered name
      reg_name != nil and String.contains?(mfa_str || "", "GenServer") ->
        {"GenServer", shorten_module_name(reg_name)}

      # Telemetry
      String.contains?(mfa_str || "", "Telemetry") ->
        {"Telemetry", shorten_module_name(reg_name || "Handler")}

      # Logger
      String.contains?(mfa_str || "", "Logger") ->
        {"Logger", shorten_module_name(reg_name || "Backend")}

      true ->
        nil
    end
  end

  defp is_supervisor?(mfa_str, reg_name) do
    String.contains?(mfa_str || "", "Supervisor") or
    String.contains?(reg_name || "", "Supervisor") or
    String.ends_with?(reg_name || "", ".Sup")
  end

  # =============================================================================
  # Pool Worker Detection
  # =============================================================================

  defp detect_pool_worker(target, ancestors, initial_call) do
    mfa_str = format_mfa(initial_call)

    cond do
      # Poolboy worker
      ancestor_contains?(target, ancestors, "poolboy") or
      ancestor_contains?(target, ancestors, ":poolboy_sup") ->
        pool_name = find_pool_name(target, ancestors) || "Pool"
        {"Pool", "#{shorten_module_name(pool_name)}:worker"}

      # NimblePool
      String.contains?(mfa_str || "", "NimblePool") or
      ancestor_contains?(target, ancestors, "NimblePool") ->
        pool_name = find_nimble_pool_name(target, ancestors) || "Pool"
        {"NimblePool", shorten_module_name(pool_name)}

      # DBConnection pool (Ecto, Postgrex, etc.)
      String.contains?(mfa_str || "", "DBConnection.Connection") ->
        repo_name = find_repo_name(target, ancestors) || "DB"
        {"DBPool", "#{shorten_module_name(repo_name)}:conn"}

      # Finch connection pool
      String.contains?(mfa_str || "", "Finch") or
      ancestor_contains?(target, ancestors, "Finch") ->
        {"HTTP Pool", "Finch:conn"}

      # Mint connection
      String.contains?(mfa_str || "", "Mint") ->
        {"HTTP", "Mint:conn"}

      true ->
        nil
    end
  end

  # =============================================================================
  # Label Building from MFA
  # =============================================================================

  defp build_label_from_mfa(target, {mod, fun, _arity}, ancestors) do
    mod_str = mod |> Atom.to_string() |> String.replace("Elixir.", "")

    # Determine category
    category = cond do
      String.contains?(mod_str, "Supervisor") -> "Sup"
      String.contains?(mod_str, "Server") or fun == :init -> "GenServer"
      String.contains?(mod_str, "Worker") -> "Worker"
      String.contains?(mod_str, "Handler") -> "Handler"
      String.contains?(mod_str, "Consumer") -> "Consumer"
      String.contains?(mod_str, "Producer") -> "Producer"
      true -> "Process"
    end

    # Build short label
    short_mod = shorten_module_name(mod_str)

    # Add ancestor context if module name is generic
    label = if generic_module_name?(short_mod) do
      case find_meaningful_ancestor(target, ancestors) do
        nil -> short_mod
        ancestor -> "#{shorten_module_name(ancestor)}:#{short_mod}"
      end
    else
      short_mod
    end

    {category, label}
  end

  defp build_label_from_mfa(_target, nil, _ancestors), do: {"?", "unknown"}

  defp generic_module_name?(name) do
    name in ["Worker", "Server", "Handler", "Consumer", "Producer", "Process", "init"]
  end

  # =============================================================================
  # Ancestor Analysis
  # =============================================================================

  defp find_meaningful_ancestor(target, ancestors) do
    ancestors
    |> Enum.take(5)  # Don't go too deep
    |> Enum.find_value(fn ancestor ->
      name = get_ancestor_name(target, ancestor)
      if meaningful_name?(name), do: name, else: nil
    end)
  end

  defp get_ancestor_name(target, ancestor) when is_pid(ancestor) do
    case safe_rpc(target, :erlang, :process_info, [ancestor, :registered_name]) do
      {:registered_name, name} when is_atom(name) and name != nil ->
        name |> Atom.to_string() |> String.replace("Elixir.", "")
      _ ->
        nil
    end
  end

  defp get_ancestor_name(_target, ancestor) when is_atom(ancestor) do
    ancestor |> Atom.to_string() |> String.replace("Elixir.", "")
  end

  defp get_ancestor_name(_target, _), do: nil

  defp ancestor_contains?(target, ancestors, pattern) do
    Enum.any?(ancestors, fn ancestor ->
      name = get_ancestor_name(target, ancestor)
      name != nil and String.contains?(String.downcase(name), String.downcase(pattern))
    end)
  end

  defp meaningful_name?(nil), do: false
  defp meaningful_name?(name) do
    # Skip generic system names
    not String.starts_with?(name, "Elixir.") and
    name not in ["supervisor", "gen_server", "application_master", "kernel_sup", "code_server"] and
    not String.contains?(name, "#PID")
  end

  # =============================================================================
  # Pool Name Extraction
  # =============================================================================

  defp find_pool_name(target, ancestors) do
    ancestors
    |> Enum.find_value(fn ancestor ->
      name = get_ancestor_name(target, ancestor)
      cond do
        name == nil -> nil
        String.contains?(name, "Pool") -> name
        String.ends_with?(name, ".Sup") -> String.replace_suffix(name, ".Sup", "")
        true -> nil
      end
    end)
  end

  defp find_nimble_pool_name(target, ancestors) do
    find_pool_name(target, ancestors)
  end

  defp find_repo_name(target, ancestors) do
    ancestors
    |> Enum.find_value(fn ancestor ->
      name = get_ancestor_name(target, ancestor)
      cond do
        name == nil -> nil
        String.contains?(name, "Repo") -> name
        String.contains?(name, "Pool") -> name
        true -> nil
      end
    end)
  end

  # =============================================================================
  # Module Name Shortening
  # =============================================================================

  defp shorten_module_name(nil), do: "?"

  defp shorten_module_name(name) when is_binary(name) do
    name
    |> String.replace("Elixir.", "")
    |> String.split(".")
    |> case do
      # Single word - keep as is
      [single] -> single

      # Two parts - keep both
      [a, b] -> "#{a}.#{b}"

      # Three+ parts - keep last two meaningful parts
      parts ->
        parts
        |> Enum.reject(&(&1 in ["Supervisor", "Server", "Worker", "Sup"]))
        |> Enum.take(-2)
        |> Enum.join(".")
        |> case do
          "" -> List.last(parts)
          short -> short
        end
    end
    |> String.replace(~r/Supervisor$/, "Sup")
    |> String.replace(~r/Controller$/, "Ctrl")
    |> String.replace(~r/Handler$/, "Hndlr")
  end

  defp shorten_module_name(atom) when is_atom(atom) do
    shorten_module_name(Atom.to_string(atom))
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp extract_module_name({mod, _fun, _arity}) when is_atom(mod) do
    mod |> Atom.to_string() |> String.replace("Elixir.", "")
  end
  defp extract_module_name(_), do: nil

  defp extract_task_function({_mod, fun, _arity}) when is_atom(fun) do
    Atom.to_string(fun)
  end
  defp extract_task_function(_), do: nil

  defp format_mfa({mod, fun, arity}) when is_atom(mod) and is_atom(fun) do
    mod_str = mod |> Atom.to_string() |> String.replace("Elixir.", "")
    "#{mod_str}.#{fun}/#{arity}"
  end
  defp format_mfa(_), do: nil

  defp categorize_registered_name(name) do
    cond do
      String.contains?(name, "Supervisor") or String.ends_with?(name, ".Sup") -> "Sup"
      String.contains?(name, "Registry") -> "Registry"
      String.contains?(name, "Pool") -> "Pool"
      String.contains?(name, "Cache") -> "Cache"
      String.contains?(name, "Server") -> "GenServer"
      String.contains?(name, "Manager") -> "Manager"
      String.contains?(name, "Worker") -> "Worker"
      true -> "Named"
    end
  end

  defp safe_rpc(target, mod, fun, args) do
    if target == node() do
      apply(mod, fun, args)
    else
      case :rpc.call(target, mod, fun, args, 2000) do
        {:badrpc, _} -> nil
        result -> result
      end
    end
  rescue
    _ -> nil
  end

  # Intelligently shorten name to show rightmost distinct Module.Function/Arity
  defp shorten_name(name, max_len) when is_binary(name) do
    if String.length(name) <= max_len do
      name
    else
      {prefix, rest} =
        case String.split(name, "/", parts: 2) do
          [app, rest] -> {"#{app}/", rest}
          _ -> {"", name}
        end

      parts = String.split(rest, ".")

      short =
        case parts do
          [single] ->
            String.slice(single, 0, max_len - 2) <> ".."

          parts when length(parts) >= 2 ->
            [second_last, last] = Enum.take(parts, -2)
            candidate = "#{second_last}.#{last}"

            if String.length(prefix) + String.length(candidate) <= max_len do
              candidate
            else
              available = max_len - String.length(prefix) - String.length(last) - 3
              if available > 3 do
                String.slice(second_last, 0, available) <> "..#{last}"
              else
                String.slice(candidate, -max_len + 2, max_len - 2) <> ".."
              end
            end

          _ ->
            String.slice(rest, 0, max_len - 2) <> ".."
        end

      prefix <> short
    end
  end

  defp shorten_name(nil, _max_len), do: "-"
  defp shorten_name(other, max_len) when not is_binary(other), do: shorten_name(inspect(other), max_len)

  defp build_graph(procs, config) do
    c = ColorScheme.current()

    # Find max value for scaling bars
    max_val = procs |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end)

    s = config.scale
    border_w = max(1, round(3 * s))

    Graph.build(font: :courier, font_size: max(12, round(30 * s)))
    |> rect({config.width, config.height}, fill: c.bg, stroke: {border_w, c.border})
    |> draw_rows(procs, max_val, config, c)
    |> draw_watermark(config, c, procs)
  end

  defp draw_rows(graph, [], _max_val, config, c) do
    # Show message when no data
    s = config.scale
    graph
    |> text("No data - check node connection",
      fill: c.warning,
      font: :courier,
      font_size: max(12, round(26 * s)),
      translate: {config.width / 2 - 250 * s, config.height / 2}
    )
  end

  defp draw_rows(graph, procs, max_val, config, c) do
    s = config.scale
    visible = Enum.filter(procs, fn p -> (p.value || 0) > 0 end)
    top_pad = 8 * s
    rows_height = config.height - top_pad * 2
    row_height = rows_height / 5

    visible
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_row(g, proc, idx, max_val, config, c, row_height)
    end)
  end

  defp draw_row(graph, proc, idx, max_val, config, c, row_height) do
    s = config.scale
    top_pad = 8 * s
    y = top_pad + (idx - 1) * row_height
    row_inner_height = row_height - 4 * s
    bar_height = max(row_inner_height - 16 * s, 12 * s)

    # Layout: 60% text, 40% meter
    text_width = config.width * 0.6
    meter_x = text_width
    meter_width = config.width - meter_x - 10 * s


    # Process name - show registered name or module.function
    name_str = shorten_name(proc.name, 20)

    # Value - GB with 2 decimals for memory
    value_str = format_value_display(proc.value, config.attribute)

    # Calculate bar fill ratio
    ratio = if max_val > 0, do: proc.value / max_val, else: 0

    # Bar dimensions - full height, skinny segments
    segment_width = meter_width / @bar_segments
    segment_gap = max(1, round(2 * s))
    corner_radius = max(1, round(4 * s))

    # Color gradient based on ranking
    bar_colors = get_bar_colors(idx, c)

    # Type color based on process type (unused when type label hidden)
    # type_color = get_type_color(type_str, c)

    graph
    # Name - full left area
    |> text(name_str,
      fill: c.primary,
      font: :courier,
      font_size: max(trunc(row_inner_height * 0.45), round(14 * s)),
      translate: {8 * s, y + row_inner_height / 2 + 6 * s}
    )
    # Value - in the 10% area before meter
    |> text(value_str,
      fill: {255, 180, 0},
      font: :courier_bold,
      font_size: max(trunc(row_inner_height * 0.8), round(18 * s)),
      text_align: :right,
      translate: {meter_x - 4 * s, y + row_inner_height * 0.85}
    )
    # Draw bar segments - slimmer to match text height
    |> draw_bar_segments(
      meter_x,
      y + (row_inner_height - bar_height) / 2 + 4 * s,
      segment_width,
      segment_gap,
      bar_height,
      ratio,
      corner_radius,
      bar_colors,
      c
    )
  end


  # Format value for display in the value column
  defp format_value_display(bytes, :memory) do
    mb = bytes / 1024 / 1024
    Integer.to_string(round(mb))
  end

  defp format_value_display(count, :message_queue_len) do
    Integer.to_string(count)
  end

  defp format_value_display(value, _), do: inspect(value)

  defp draw_bar_segments(graph, bar_x, bar_y, segment_width, gap, height, ratio, corner_radius, colors, c) do
    active_segments = trunc(ratio * @bar_segments)

    Enum.reduce(0..(@bar_segments - 1), graph, fn i, g ->
      x = bar_x + i * segment_width
      active = i < active_segments
      color = Enum.at(colors, i, c.secondary)

      fill =
        if active do
          color
        else
          {0, 0, 0}
        end

      g
      |> rrect({segment_width - gap, height, corner_radius},
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

  defp draw_watermark(graph, config, c, procs) do
    s = config.scale
    area_w = config.width * 0.4
    area_h = config.height * 0.4
    label_font = max(12, round(min(area_w, area_h) * 0.35))
    value_font = max(10, round(min(area_w, area_h) * 0.2)) * 4
    x = config.width - 12 * s
    y = config.height - 12 * s
    label = if config.attribute == :memory, do: "PROC MEM MB", else: "PROC MSGQ"
    value = top5_total(procs, config.attribute)
    fill_limit = top5_fill_limit(procs, config)

    graph
    |> draw_inverted_value(value, value_font, x, y - label_font * 2.6, fill_limit)
    |> text(label,
      fill: with_alpha(c.secondary, 80),
      font: :courier_bold,
      font_size: label_font,
      text_align: :right,
      translate: {x, y}
    )
  end

  defp with_alpha({r, g, b}, a), do: {r, g, b, a}
  defp with_alpha({r, g, b, _}, a), do: {r, g, b, a}

  defp draw_inverted_value(graph, value, font_size, right_x, y, fill_limit) do
    {:ok, {Scenic.Assets.Static.Font, fm}} = Scenic.Assets.Static.meta(:courier_bold)
    total_w = FontMetrics.width(value, font_size, fm)
    start_x = right_x - total_w

    value
    |> String.graphemes()
    |> Enum.reduce({graph, start_x}, fn ch, {g, x} ->
      w = FontMetrics.width(ch, font_size, fm)
      color = if fill_limit >= x + w / 2, do: {0, 0, 0}, else: {255, 140, 0}

      g =
        g
        |> text(ch,
          fill: color,
          font: :courier_bold,
          font_size: font_size,
          translate: {x, y}
        )

      {g, x + w}
    end)
    |> elem(0)
  end

  defp top5_fill_limit(procs, config) do
    s = config.scale
    top_pad = 8 * s
    rows_height = config.height - top_pad * 2
    row_height = rows_height / 5
    row_inner_height = row_height - 4 * s
    bar_height = max(row_inner_height - 16 * s, 12 * s)
    text_width = config.width * 0.6
    meter_x = text_width
    meter_width = config.width - meter_x - 10 * s

    middle =
      procs
      |> Enum.filter(fn p -> (p.value || 0) > 0 end)
      |> Enum.at(2)

    sum =
      procs
      |> Enum.map(&(&1.value || 0))
      |> Enum.sum()

    ratio =
      case middle do
        nil -> 0.0
        proc -> if sum > 0, do: proc.value / sum, else: 0.0
      end

    bar_x = meter_x
    _bar_y = top_pad + (row_inner_height - bar_height) / 2 + 4 * s
    fill_limit = bar_x + meter_width * ratio
    max(fill_limit, bar_x)
  end

  defp top5_total(procs, :memory) do
    bytes = procs |> Enum.map(&(&1.value || 0)) |> Enum.sum()
    mb = bytes / 1024 / 1024
    Integer.to_string(round(mb))
  end

  defp top5_total(procs, :message_queue_len) do
    procs |> Enum.map(&(&1.value || 0)) |> Enum.sum() |> Integer.to_string()
  end

  defp top5_total(procs, _), do: procs |> Enum.map(&(&1.value || 0)) |> Enum.sum() |> Integer.to_string()
end
