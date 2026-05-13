defmodule Zonia.Boards.Style do
  @moduledoc """
  Behaviour for a board's side-channel style metadata.

  Every character in a board's `map.txt` must appear in the corresponding
  style module's `style/0`. Unknown characters fail the parser loudly.

  A style entry is a map with these keys:

    * `:kind` — required. One of `:tile`, `:edge_north`, `:edge_south`,
      `:edge_east`, `:edge_west`, or `:decor`. The parser uses this to
      build the graph; everything else is for rendering.
    * `:color` — optional atom. Forwarded to the client and mapped to a
      theme tone there. Atoms like `:cyan`, `:magenta`, `:green` are
      conventional but free-form.
    * `:effect` — optional atom on `:tile` entries. One of `:minigame`,
      `:mystery`, `:star_shop`, or any future effect. `nil` means a
      plain tile.
    * `:start` — optional boolean on `:tile` entries. Exactly one tile
      across the whole style must be `start: true`.

  Example:

      defmodule Zonia.Boards.MyBoard.Style do
        @behaviour Zonia.Boards.Style

        @impl true
        def style do
          %{
            "●" => %{kind: :tile, color: :cyan},
            "★" => %{kind: :tile, color: :yellow, effect: :star_shop, start: true},
            "→" => %{kind: :edge_east, color: :cyan},
            "🌲" => %{kind: :decor, color: :green},
            " " => %{kind: :decor, color: :default}
          }
        end
      end
  """

  @type kind ::
          :tile | :edge_north | :edge_south | :edge_east | :edge_west | :decor

  @type entry :: %{
          required(:kind) => kind(),
          optional(:color) => atom(),
          optional(:effect) => atom() | nil,
          optional(:start) => boolean()
        }

  @type t :: %{String.t() => entry()}

  @callback style() :: t()
end
