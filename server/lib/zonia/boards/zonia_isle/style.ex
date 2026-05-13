defmodule Zonia.Boards.ZoniaIsle.Style do
  @moduledoc """
  Side-channel style for the zonia-isle board.

  Every grapheme in `priv/boards/zonia-isle/map.txt` must appear here.
  """
  @behaviour Zonia.Boards.Style

  @impl true
  def style do
    %{
      # Path tiles
      "●" => %{kind: :tile, color: :cyan},
      "M" => %{kind: :tile, color: :magenta, effect: :minigame},
      "?" => %{kind: :tile, color: :yellow, effect: :mystery},
      "★" => %{kind: :tile, color: :yellow, effect: :star_shop, start: true},

      # Directional one-way edges
      "→" => %{kind: :edge_east, color: :cyan},
      "←" => %{kind: :edge_west, color: :cyan},
      "↑" => %{kind: :edge_north, color: :cyan},
      "↓" => %{kind: :edge_south, color: :cyan},

      # Decor — parser ignores; client renders.
      "🌲" => %{kind: :decor, color: :green},
      "🌊" => %{kind: :decor, color: :blue},
      "△" => %{kind: :decor, color: :gray},
      " " => %{kind: :decor, color: :default}
    }
  end
end
