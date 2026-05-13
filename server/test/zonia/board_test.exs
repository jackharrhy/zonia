defmodule Zonia.BoardTest do
  use ExUnit.Case, async: true

  alias Zonia.Board
  alias Zonia.Board.ParseError

  # Small inline style helpers so each test is self-contained and doesn't
  # break if the shipped board's style is later edited.

  defp base_style do
    %{
      "●" => %{kind: :tile, color: :cyan},
      "★" => %{kind: :tile, color: :yellow, start: true},
      "→" => %{kind: :edge_east, color: :cyan},
      "←" => %{kind: :edge_west, color: :cyan},
      "↑" => %{kind: :edge_north, color: :cyan},
      "↓" => %{kind: :edge_south, color: :cyan},
      " " => %{kind: :decor, color: :default}
    }
  end

  defp style_with(extra), do: Map.merge(base_style(), extra)

  describe "parse/3 — happy paths" do
    test "single line of tiles: endpoints have one outgoing edge, interior tiles have two" do
      raw = "★●●●"
      board = Board.parse("line", raw, base_style())

      assert board.name == "line"
      assert board.raw == raw
      assert board.width == 4
      assert board.height == 1
      assert board.start == {0, 0}
      assert map_size(board.tiles) == 4

      # Left endpoint: only east.
      assert dirs(board, {0, 0}) == [:east]
      assert targets(board, {0, 0}) == [{0, 1}]

      # Interior tiles: east + west.
      assert Enum.sort(dirs(board, {0, 1})) == [:east, :west]
      assert Enum.sort(targets(board, {0, 1})) == [{0, 0}, {0, 2}]
      assert Enum.sort(dirs(board, {0, 2})) == [:east, :west]

      # Right endpoint: only west.
      assert dirs(board, {0, 3}) == [:west]
      assert targets(board, {0, 3}) == [{0, 2}]
    end

    test "rectangular loop: every tile has degree 2" do
      raw =
        """
        ★●●
        ● ●
        ●●●
        """
        |> String.trim_trailing("\n")

      board = Board.parse("loop", raw, base_style())

      assert board.width == 3
      assert board.height == 3
      # 8 tiles around the perimeter; the centre is a decor space.
      assert map_size(board.tiles) == 8

      # Every tile on the loop has exactly two outgoing edges.
      for {_pos, tile} <- board.tiles do
        assert length(tile.outgoing) == 2
      end

      assert board.start == {0, 0}
    end

    test "T-junction tile has three outgoing edges" do
      # ●●●
      #  ★
      #  ●
      raw =
        """
        ●●●
         ★
         ●
        """
        |> String.trim_trailing("\n")

      board = Board.parse("tee", raw, base_style())

      # Junction at (0,1): west, east, south.
      assert Enum.sort(dirs(board, {0, 1})) == [:east, :south, :west]
      assert Enum.sort(targets(board, {0, 1})) == [{0, 0}, {0, 2}, {1, 1}]

      # Each leaf endpoint has exactly one edge.
      assert dirs(board, {0, 0}) == [:east]
      assert dirs(board, {0, 2}) == [:west]
      assert dirs(board, {2, 1}) == [:north]

      assert board.start == {1, 1}
    end

    test "decor characters (space + custom) are ignored for tile counting" do
      style =
        style_with(%{
          "🌲" => %{kind: :decor, color: :green},
          "🌊" => %{kind: :decor, color: :blue}
        })

      raw =
        """
        🌲★●🌊
        🌲 ●🌊
        """
        |> String.trim_trailing("\n")

      board = Board.parse("decor", raw, style)

      # Only 3 tile cells: ★ at (0,1), ● at (0,2), ● at (1,2). The 🌲 and
      # 🌊 decor characters and the space are ignored.
      assert map_size(board.tiles) == 3
      assert Map.has_key?(board.tiles, {0, 1})
      assert Map.has_key?(board.tiles, {0, 2})
      assert Map.has_key?(board.tiles, {1, 2})
      refute Map.has_key?(board.tiles, {0, 0})
      refute Map.has_key?(board.tiles, {1, 1})
    end

    test "effects are carried through to tiles" do
      style =
        style_with(%{
          "M" => %{kind: :tile, color: :magenta, effect: :minigame},
          "?" => %{kind: :tile, color: :yellow, effect: :mystery}
        })

      raw = "★M?●"
      board = Board.parse("fx", raw, style)

      assert board.tiles[{0, 0}].effect == nil
      assert board.tiles[{0, 0}].start == true
      assert board.tiles[{0, 1}].effect == :minigame
      assert board.tiles[{0, 1}].color == :magenta
      assert board.tiles[{0, 2}].effect == :mystery
      assert board.tiles[{0, 3}].effect == nil
      assert board.tiles[{0, 3}].char == "●"
    end

    test "start position points at the unique start: true tile" do
      raw = "●●★●●"
      board = Board.parse("start", raw, base_style())

      assert board.start == {0, 2}
      assert board.tiles[{0, 2}].start == true

      refute board.tiles[{0, 0}].start
      refute board.tiles[{0, 1}].start
      refute board.tiles[{0, 3}].start
      refute board.tiles[{0, 4}].start
    end
  end

  describe "parse/3 — one-way edges" do
    test "→ creates a one-way east edge; no west edge back" do
      # ★→●● — the right ● has a west neighbour (middle ●) so it isn't
      # orphaned. The arrow gives ★ a one-way east edge, but the middle
      # ● does NOT get a west edge back through the arrow.
      raw = "★→●●"
      board = Board.parse("east", raw, base_style())

      assert map_size(board.tiles) == 3

      # ★ → ● across the arrow.
      assert targets(board, {0, 0}) == [{0, 2}]
      assert dirs(board, {0, 0}) == [:east]

      # Middle ● only connects east (no west back through arrow).
      assert dirs(board, {0, 2}) == [:east]
      assert targets(board, {0, 2}) == [{0, 3}]

      # Right ● only connects west.
      assert dirs(board, {0, 3}) == [:west]
    end

    test "← creates a one-way west edge" do
      raw = "●●←★"
      board = Board.parse("west", raw, base_style())

      assert map_size(board.tiles) == 3

      # ★ at (0,3) → west to (0,1) across the arrow.
      assert dirs(board, {0, 3}) == [:west]
      assert targets(board, {0, 3}) == [{0, 1}]

      # (0,1) has no east edge back through the arrow; only its west tile-neighbour.
      assert dirs(board, {0, 1}) == [:west]
      assert targets(board, {0, 1}) == [{0, 0}]

      assert dirs(board, {0, 0}) == [:east]
    end

    test "↑ creates a one-way north edge" do
      raw =
        """
        ★●
        ↑\s
        ●●
        """
        |> String.trim_trailing("\n")

      board = Board.parse("north", raw, base_style())

      # (2,0) north via ↑ at (1,0) to (0,0)=★.
      assert {{0, 0}, :north} in board.tiles[{2, 0}].outgoing
      # ★ has only its east neighbour — no south edge back through the arrow.
      assert dirs(board, {0, 0}) == [:east]
    end

    test "↓ creates a one-way south edge" do
      raw =
        """
        ★●
        ↓\s
        ●●
        """
        |> String.trim_trailing("\n")

      board = Board.parse("south", raw, base_style())

      # ★ at (0,0) south to (2,0) via ↓.
      assert {{2, 0}, :south} in board.tiles[{0, 0}].outgoing
      assert Enum.sort(dirs(board, {0, 0})) == [:east, :south]

      # (2,0) has no north edge back.
      assert dirs(board, {2, 0}) == [:east]
    end

    test "a → arrow does not create a vertical edge between tiles above/below it" do
      # ★●●
      # ●→●
      # ●●●
      #
      # The → at (1,1) sits between (1,0) and (1,2) — valid one-way east.
      # The tiles above and below it must NOT gain a vertical edge that
      # passes through the arrow, because edge_east ≠ edge_north/south.
      raw =
        """
        ★●●
        ●→●
        ●●●
        """
        |> String.trim_trailing("\n")

      board = Board.parse("misaligned", raw, base_style())

      east_targets =
        board.tiles[{1, 0}].outgoing
        |> Enum.filter(fn {_p, dir} -> dir == :east end)
        |> Enum.map(&elem(&1, 0))

      assert east_targets == [{1, 2}]

      south_from_top =
        board.tiles[{0, 1}].outgoing
        |> Enum.filter(fn {_p, dir} -> dir == :south end)

      assert south_from_top == []

      north_from_bottom =
        board.tiles[{2, 1}].outgoing
        |> Enum.filter(fn {_p, dir} -> dir == :north end)

      assert north_from_bottom == []

      west_back =
        board.tiles[{1, 2}].outgoing
        |> Enum.filter(fn {_p, dir} -> dir == :west end)

      assert west_back == []
    end
  end

  describe "parse/3 — errors" do
    test "unknown character in map but not in style" do
      raw = "★●X"

      error =
        assert_raise ParseError, fn ->
          Board.parse("unknown", raw, base_style())
        end

      assert error.message =~ "unknown character"
      assert error.message =~ "X"
      assert error.message =~ "unknown"
    end

    test "no start tile raises" do
      style = Map.delete(base_style(), "★")
      raw = "●●●"

      error =
        assert_raise ParseError, fn ->
          Board.parse("nostart", raw, style)
        end

      assert error.message =~ "no start tile"
    end

    test "multiple start tiles raise" do
      raw = "★★"

      error =
        assert_raise ParseError, fn ->
          Board.parse("doublestart", raw, base_style())
        end

      assert error.message =~ "multiple start tiles"
    end

    test "orphan tile (no walkable neighbours) raises" do
      # ★ and ● both isolated by decor — parser raises on the first
      # orphan it encounters.
      raw =
        """
        ★
         \s
         ●
        """
        |> String.trim_trailing("\n")

      error =
        assert_raise ParseError, fn ->
          Board.parse("orphan", raw, base_style())
        end

      assert error.message =~ "orphan tile"
    end

    test "dangling arrow at the edge of the map raises" do
      # ★●→  — the trailing → has a tile west but nothing east. Dangling.
      raw = "★●→"

      error =
        assert_raise ParseError, fn ->
          Board.parse("dangling_edge", raw, base_style())
        end

      assert error.message =~ "dangling"
      assert error.message =~ "edge_east"
    end

    test "dangling arrow with decor on one side raises" do
      # ★● →   — the arrow has a tile to its west but decor to its east.
      raw = "★● → "

      error =
        assert_raise ParseError, fn ->
          Board.parse("dangling_decor", raw, base_style())
        end

      assert error.message =~ "dangling"
    end
  end

  describe "public_view/1" do
    test "returns the expected shape with start as a 2-element list (not a tuple)" do
      raw = "★●●"
      board = Board.parse("pv", raw, base_style())
      view = Board.public_view(board)

      assert is_map(view)
      assert view.name == "pv"
      assert view.raw == raw
      assert view.width == 3
      assert view.height == 1
      assert view.start == [0, 0]
      refute is_tuple(view.start)
      assert is_list(view.start)
      assert length(view.start) == 2
    end

    test "style keys remain strings; entry values are atom-stringified" do
      style = %{
        "●" => %{kind: :tile, color: :cyan},
        "★" => %{kind: :tile, color: :yellow, effect: :star_shop, start: true},
        "→" => %{kind: :edge_east, color: :cyan},
        " " => %{kind: :decor, color: :default}
      }

      # ●★→●● avoids orphaning the rightmost tile (its only would-be
      # neighbour through the arrow is one-way in; we add another ● for
      # a west-back edge).
      raw = "●★→●●"

      board = Board.parse("pv_style", raw, style)
      view = Board.public_view(board)

      assert Enum.sort(Map.keys(view.style)) == [" ", "→", "●", "★"]

      # Tile entry — atoms stringified to their string equivalents.
      assert view.style["●"] == %{"kind" => "tile", "color" => "cyan"}

      # Tile with effect + start: start stays boolean, atoms become strings.
      assert view.style["★"] == %{
               "kind" => "tile",
               "color" => "yellow",
               "effect" => "star_shop",
               "start" => true
             }

      # Edge entry.
      assert view.style["→"] == %{"kind" => "edge_east", "color" => "cyan"}

      # Decor entry.
      assert view.style[" "] == %{"kind" => "decor", "color" => "default"}
    end
  end

  ## ── helpers ────────────────────────────────────────────────────────────

  defp dirs(board, pos) do
    board.tiles[pos].outgoing |> Enum.map(&elem(&1, 1))
  end

  defp targets(board, pos) do
    board.tiles[pos].outgoing |> Enum.map(&elem(&1, 0))
  end
end
