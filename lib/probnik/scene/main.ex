defmodule Probnik.Scene.Main do
  use Scenic.Scene

  alias Scenic.Graph
  import Scenic.Primitives

  alias Probnik.ColorScheme
  alias Probnik.Component.ProcessesWidget

  @screen_width 2388
  @screen_height 1668

  @impl Scenic.Scene
  def init(scene, _params, _opts) do
    c = ColorScheme.current()

    graph =
      Graph.build(font: :roboto, font_size: 24)
      |> rect({@screen_width, @screen_height}, fill: c.bg)
      # Title
      |> text("Probnik - Process Monitor",
        fill: c.primary,
        font_size: 48,
        translate: {40, 60}
      )
      # Processes widget
      |> ProcessesWidget.add_to_graph([
        width: @screen_width - 80,
        height: @screen_height - 120,
        limit: 45,
        sort_by: :message_queue_len,
        sort_dir: :desc
      ],
        translate: {40, 100}
      )

    scene
    |> push_graph(graph)
    |> then(&{:ok, &1})
  end
end
