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
  @screen_width 1668
  @screen_height 2388

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    Logger.info("Probnik.Scene.Main init()")
    c = ColorScheme.current()

    # 1x4 stacked layout (portrait)
    padding_x = 30
    padding_top = 30
    padding_bottom = 20
    row_gap = 10
    widget_width = @screen_width - padding_x * 2
    available_height = @screen_height - padding_top - padding_bottom - row_gap * 3
    widget_height = available_height / 4

    graph =
      Graph.build(font: :courier, font_size: 24)
      |> rect({@screen_width, @screen_height}, fill: c.bg)
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

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end
end
