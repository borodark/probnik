defmodule Probnik.Scene.Main do
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  alias Probnik.ColorScheme
  alias Probnik.Component.BarGaugeWidget

  # Portrait orientation
  @screen_width 1668
  @screen_height 2388

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    c = ColorScheme.current()

    # Horizontal split - top and bottom halves
    widget_width = @screen_width - 60
    widget_height = (@screen_height - 140) / 2

    graph =
      Graph.build(font: :roboto, font_size: 24)
      |> rect({@screen_width, @screen_height}, fill: c.bg)
      # Title
      |> text("PROBNIK",
        fill: c.primary,
        font_size: 56,
        translate: {30, 55}
      )
      |> text("Node Health Monitor",
        fill: c.secondary,
        font_size: 32,
        translate: {30, 95}
      )
      # Top widget: Memory Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :memory,
        title: "MEMORY TOP 5"
      ],
        id: :memory_top5,
        translate: {30, 120}
      )
      # Bottom widget: Message Queue Top 5
      |> BarGaugeWidget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :message_queue_len,
        title: "MESSAGE QUEUE TOP 5"
      ],
        id: :msgq_top5,
        translate: {30, 120 + widget_height + 20}
      )

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end
end
