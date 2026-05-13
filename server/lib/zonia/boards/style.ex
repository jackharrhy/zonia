defmodule Zonia.Boards.Style do
  @moduledoc """
  Behaviour for a board's side-channel style metadata.

  Boards have three character classes:

    * **Nodes** — graph vertices. Players stop at them; branches happen
      here. Examples: `"S"` (start), `"X"` (plain corner), `"M"` (mini-
      game tile), `"?"` (mystery tile).
    * **Edges** — graph segments connecting two nodes. Players walk
      through them one cell at a time. Examples: `"-"` (horizontal),
      `"|"` (vertical).
    * **Decor** — everything else: frame chars, background fill, scenery.
      Ignored by the parser; rendered as-is by the client with optional
      per-char color hints.

  ### Required callbacks

    * `nodes/0` — a map from char to `%{kind: :start | :node | atom(),
      color: atom(), effect: atom() | nil}`. Exactly one node entry
      must have `kind: :start`.
    * `edges/0` — a map from char to `%{axis: :horizontal | :vertical,
      color: atom()}`.

  ### Optional callbacks

    * `decor/0` — a map from char to `%{color: atom()}`. Anything not
      in this map renders with a default muted color. Useful for
      coloring background fill or frame chars.

  Unknown characters in the map are **silently treated as decor**. The
  parser doesn't fail on them — they just don't participate in the
  graph.

  Example:

      defmodule Zonia.Boards.MyBoard.Style do
        @behaviour Zonia.Boards.Style

        @impl true
        def nodes do
          %{
            "S" => %{kind: :start, color: :yellow},
            "X" => %{kind: :node,  color: :cyan},
            "M" => %{kind: :node,  color: :magenta, effect: :minigame},
            "?" => %{kind: :node,  color: :yellow,  effect: :mystery}
          }
        end

        @impl true
        def edges do
          %{
            "-" => %{axis: :horizontal, color: :cyan},
            "|" => %{axis: :vertical,   color: :cyan}
          }
        end

        @impl true
        def decor do
          %{
            "▒" => %{color: :gray},
            "│" => %{color: :gray},
            "═" => %{color: :gray}
          }
        end
      end
  """

  @type node_kind :: :start | :node

  @type node_entry :: %{
          required(:kind) => node_kind(),
          optional(:color) => atom(),
          optional(:effect) => atom() | nil
        }

  @type edge_axis :: :horizontal | :vertical

  @type edge_entry :: %{
          required(:axis) => edge_axis(),
          optional(:color) => atom()
        }

  @type decor_entry :: %{
          optional(:color) => atom()
        }

  @callback nodes() :: %{String.t() => node_entry()}
  @callback edges() :: %{String.t() => edge_entry()}
  @callback decor() :: %{String.t() => decor_entry()}

  @optional_callbacks decor: 0
end
