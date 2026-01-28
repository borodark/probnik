defmodule Probnik.Scene.Main do
  use Scenic.Scene

  require Logger

  alias Scenic.Graph
  import Scenic.Primitives

  alias Probnik.ColorScheme
  alias Probnik.Component.BarGaugeWidget
  alias Probnik.Component.SchedulerPressureWidget
  alias Probnik.Component.MemoryBreakdownWidget

  # Portrait orientation
  @base_width 1668
  @base_height 2388

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    Logger.info("Probnik.Scene.Main init()")
    c = ColorScheme.current()
    {vw, vh} = scene.viewport.size
    sx = vw / @base_width
    sy = vh / @base_height
    s = min(sx, sy)

    # 1x4 stacked layout (portrait)
    padding_x = 30 * sx
    padding_top = 30 * sy
    padding_bottom = 50 * sy  # Extra space for footer
    row_gap = 10 * sy
    widget_width = vw - padding_x * 2
    available_height = vh - padding_top - padding_bottom - row_gap * 3
    widget_height = available_height / 4

    # Get connected node info
    remote_node = Application.get_env(:probnik, :remote_node, :unknown)
    footer_text = "#{remote_node}"

    graph =
      Graph.build(font: :courier, font_size: max(12, round(24 * s)))
      |> rect({vw, vh}, fill: c.bg)
      # Row 1: Memory Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :memory,
        title: "Memory Top 5"
      ],
        id: :memory_top5,
        translate: {padding_x, padding_top}
      )
      # Row 2: Message Queue Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :message_queue_len,
        title: "Message Queue Top 5"
      ],
        id: :msgq_top5,
        translate: {padding_x, padding_top + widget_height + row_gap}
      )
      # Row 3: Scheduler Pressure
      |> SchedulerPressureWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        title: "Scheduler Pressure"
      ],
        id: :scheduler_pressure,
        translate: {padding_x, padding_top + (widget_height + row_gap) * 2}
      )
      # Row 4: Memory Breakdown
      |> MemoryBreakdownWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        title: "Memory Breakdown"
      ],
        id: :memory_breakdown,
        translate: {padding_x, padding_top + (widget_height + row_gap) * 3}
      )
      # Footer: connected node
      |> text(footer_text,
        fill: c.secondary,
        font_size: max(42, round(84 * s)),
        text_align: :right,
        translate: {vw - padding_x, vh - 5}
      )

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end

  @impl Scenic.Scene
  def handle_input({:viewport, {:reshape, {w, h}}}, _id, scene) do
    c = ColorScheme.current()
    sx = w / @base_width
    sy = h / @base_height
    s = min(sx, sy)

    padding_x = 30 * sx
    padding_top = 30 * sy
    padding_bottom = 50 * sy
    row_gap = 10 * sy
    widget_width = w - padding_x * 2
    available_height = h - padding_top - padding_bottom - row_gap * 3
    widget_height = available_height / 4

    remote_node = Application.get_env(:probnik, :remote_node, :unknown)
    footer_text = "#{remote_node}"

    graph =
      Graph.build(font: :courier, font_size: max(12, round(24 * s)))
      |> rect({w, h}, fill: c.bg)
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :memory,
        title: "Memory Top 5"
      ],
        id: :memory_top5,
        translate: {padding_x, padding_top}
      )
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :message_queue_len,
        title: "Message Queue Top 5"
      ],
        id: :msgq_top5,
        translate: {padding_x, padding_top + widget_height + row_gap}
      )
      |> SchedulerPressureWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        title: "Scheduler Pressure"
      ],
        id: :scheduler_pressure,
        translate: {padding_x, padding_top + (widget_height + row_gap) * 2}
      )
      |> MemoryBreakdownWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        title: "Memory Breakdown"
      ],
        id: :memory_breakdown,
        translate: {padding_x, padding_top + (widget_height + row_gap) * 3}
      )
      |> text(footer_text,
        fill: c.secondary,
        font_size: max(42, round(84 * s)),
        text_align: :right,
        translate: {w - padding_x, h - 5}
      )

    {:noreply, scene |> push_graph(graph)}
  end

  def handle_input(_input, _id, scene), do: {:noreply, scene}
end
