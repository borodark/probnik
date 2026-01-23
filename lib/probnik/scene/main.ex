defmodule Probnik.Scene.Main do
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  alias Probnik.ColorScheme
  alias Probnik.Component.Top5Widget

  @screen_width 2388
  @screen_height 1668

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    c = ColorScheme.current()

    # Horizontal split - two widgets side by side
    widget_width = (@screen_width - 120) / 2
    widget_height = @screen_height - 160

    graph =
      Graph.build(font: :roboto, font_size: 24)
      |> rect({@screen_width, @screen_height}, fill: c.bg)
      # Title
      |> text("Probnik - Node Health",
        fill: c.primary,
        font_size: 48,
        translate: {40, 60}
      )
      # Left widget: Memory Top 5
      |> Top5Widget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :memory,
        title: "MEMORY TOP 5"
      ],
        id: :memory_top5,
        translate: {40, 100}
      )
      # Right widget: Message Queue Top 5
      |> Top5Widget.add_to_graph([
        width: widget_width,
        height: widget_height,
        attribute: :message_queue_len,
        title: "MSG QUEUE TOP 5"
      ],
        id: :msgq_top5,
        translate: {40 + widget_width + 40, 100}
      )

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end
end
