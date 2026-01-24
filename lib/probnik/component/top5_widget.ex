defmodule Probnik.Component.Top5Widget do
  @moduledoc """
  Top 5 processes widget using recon.
  Shows either memory or message_queue_len top consumers.
  Big letters, designed for horizontal split layout.
  """
  use Scenic.Component, has_children: false

  alias Scenic.Graph
  alias Probnik.ColorScheme
  import Scenic.Primitives

  @update_interval 1000
  @row_height 85
  @header_height 60

  @impl Scenic.Component
  def validate(opts) when is_list(opts), do: {:ok, opts}
  def validate(_), do: {:error, "Expected keyword list options"}

  @impl Scenic.Scene
  def init(scene, opts, _scenic_opts) do
    width = Keyword.get(opts, :width, 600)
    height = Keyword.get(opts, :height, 450)
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
          # Get the real initial call like LiveDashboard does
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
      # First: registered name
      is_atom(reg_name) and reg_name not in [nil, []] ->
        Atom.to_string(reg_name)

      # Second: real initial call from proc_lib (like LiveDashboard)
      is_tuple(real_initial_call) and tuple_size(real_initial_call) == 3 ->
        extract_mfa(real_initial_call)

      # Fallback
      true ->
        "-"
    end
  end

  defp extract_name(_, _), do: "-"

  # Extract Module.Function for cleaner display
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

    Graph.build(font: :roboto, font_size: 36)
    |> rect({config.width, config.height}, fill: c.bg, stroke: {2, c.border})
    |> draw_header(config, c)
    |> draw_rows(procs, config, c)
  end

  defp draw_header(graph, config, c) do
    graph
    |> text(config.title,
      fill: c.secondary,
      font_size: 32,
      translate: {20, 40}
    )
    |> line({{0, @header_height}, {config.width, @header_height}}, stroke: {2, c.border})
  end

  defp draw_rows(graph, procs, config, c) do
    procs
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {proc, idx}, g ->
      draw_row(g, proc, idx, config, c)
    end)
  end

  defp draw_row(graph, proc, idx, config, c) do
    y = @header_height + 10 + (idx - 1) * @row_height

    # Rank number
    rank_str = "#{idx}."

    # Process name - THE MOST VISIBLE ELEMENT (Module.Function)
    name_str = truncate(proc.name, 45)

    # Value formatting depends on attribute
    value_str = format_value(proc.value, config.attribute)

    # Color based on ranking
    rank_color =
      case idx do
        1 -> c.critical
        2 -> c.warning
        3 -> c.accent
        _ -> c.secondary
      end

    graph
    # Rank - small, left side
    |> text(rank_str,
      fill: rank_color,
      font_size: 32,
      translate: {15, y + 45}
    )
    # NAME - BIG AND PROMINENT
    |> text(name_str,
      fill: c.primary,
      font_size: 48,
      translate: {60, y + 48}
    )
    # Value - smaller, right aligned
    |> text(value_str,
      fill: rank_color,
      font_size: 32,
      text_align: :right,
      translate: {config.width - 20, y + 45}
    )
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
      true -> "#{Float.round(bytes / 1024 / 1024, 1)} MB"
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
