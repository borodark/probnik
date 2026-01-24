defmodule Probnik.Scene.Main do
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  alias Probnik.ColorScheme
  alias Probnik.Component.BarGaugeWidget
  alias Probnik.Component.SchedulerPressureWidget
  alias Probnik.Component.MemoryBreakdownWidget

  # Portrait orientation
  @screen_width 1668
  @screen_height 2388

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    c = ColorScheme.current()

    # 1x4 stacked layout (portrait)
    padding_x = 30
    padding_top = 30
    padding_bottom = 20
    row_gap = 10
    widget_width = @screen_width - padding_x * 2
    top_widget_height = 36 + 2 + 60 * 5 + 8
    bottom_total = @screen_height - padding_top - padding_bottom - row_gap * 3 - top_widget_height * 2
    scheduler_height = 250
    memory_breakdown_height = bottom_total - scheduler_height

    graph =
      Graph.build(font: :courier, font_size: 24)
      |> rect({@screen_width, @screen_height}, fill: c.bg)
      # Row 1: Memory Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: top_widget_height,
        attribute: :memory,
        title: "MEMORY TOP 5"
      ],
        id: :memory_top5,
        translate: {padding_x, padding_top}
      )
      # Row 2: Message Queue Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: top_widget_height,
        attribute: :message_queue_len,
        title: "MESSAGE QUEUE TOP 5"
      ],
        id: :msgq_top5,
        translate: {padding_x, padding_top + top_widget_height + row_gap}
      )
      # Row 3: Scheduler Pressure
      |> SchedulerPressureWidget.add_to_graph([
        width: widget_width,
        height: scheduler_height,
        title: "SCHEDULER PRESSURE"
      ],
        id: :scheduler_pressure,
        translate: {padding_x, padding_top + (top_widget_height + row_gap) * 2}
      )
      # Row 4: Memory Breakdown
      |> MemoryBreakdownWidget.add_to_graph([
        width: widget_width,
        height: memory_breakdown_height,
        title: "MEMORY BREAKDOWN"
      ],
        id: :memory_breakdown,
        translate: {padding_x, padding_top + (top_widget_height + row_gap) * 2 + scheduler_height + row_gap}
      )

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end
end
