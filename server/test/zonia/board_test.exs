defmodule Zonia.BoardTest do
  use ExUnit.Case, async: true

  alias Zonia.Board
  alias Zonia.Board.ParseError

  # Each test defines its own inline style module so cases don't share
  # state and the shipped boards' style can change without breaking tests.

  defmodule StyleS_X_Dash_Pipe do
    @behaviour Zonia.Boards.Style
    @impl true
    def nodes do
      %{
        "S" => %{kind: :start, color: :yellow},
        "X" => %{kind: :node, color: :cyan}
      }
    end

    @impl true
    def edges do
      %{
        "-" => %{axis: :horizontal, color: :cyan},
        "|" => %{axis: :vertical, color: :cyan}
      }
    end

    @impl true
    def decor, do: %{}
  end

  defmodule StyleWithEffects do
    @behaviour Zonia.Boards.Style
    @impl true
    def nodes do
      %{
        "S" => %{kind: :start, color: :yellow},
        "X" => %{kind: :node, color: :cyan},
        "M" => %{kind: :node, color: :magenta, effect: :minigame},
        "?" => %{kind: :node, color: :yellow, effect: :mystery}
      }
    end

    @impl true
    def edges do
      %{
        "-" => %{axis: :horizontal, color: :cyan},
        "|" => %{axis: :vertical, color: :cyan}
      }
    end

    @impl true
    def decor, do: %{}
  end

  defmodule StyleNoStart do
    @behaviour Zonia.Boards.Style
    @impl true
    def nodes, do: %{"X" => %{kind: :node, color: :cyan}}
    @impl true
    def edges, do: %{"-" => %{axis: :horizontal, color: :cyan}}
    @impl true
    def decor, do: %{}
  end

  defmodule StyleTwoStarts do
    @behaviour Zonia.Boards.Style
    @impl true
    def nodes do
      %{
        "S" => %{kind: :start, color: :yellow},
        "T" => %{kind: :start, color: :yellow}
      }
    end

    @impl true
    def edges, do: %{"-" => %{axis: :horizontal, color: :cyan}}
    @impl true
    def decor, do: %{}
  end

  defp edges_from(board, pos) do
    board.nodes[pos].edges
  end

  defp dirs(board, pos) do
    edges_from(board, pos) |> Enum.map(& &1.direction) |> Enum.sort()
  end

  describe "parse/3 — happy paths" do
    test "two adjacent nodes form a degree-1 edge with empty-cell path" do
      board = Board.parse("adj", "SX", StyleS_X_Dash_Pipe)
      assert board.name == "adj"
      assert board.start == {0, 0}
      assert map_size(board.nodes) == 2

      [edge] = edges_from(board, {0, 0})
      assert edge.to == {0, 1}
      assert edge.direction == :east
      # Direct adjacency: path is just the destination cell.
      assert edge.path == [{0, 1}]
    end

    test "nodes separated by horizontal edge characters" do
      board = Board.parse("h", "S---X", StyleS_X_Dash_Pipe)
      assert map_size(board.nodes) == 2

      [edge_east] = edges_from(board, {0, 0})
      assert edge_east.direction == :east
      assert edge_east.to == {0, 4}
      # Path traverses each `-` cell then arrives at the destination.
      assert edge_east.path == [{0, 1}, {0, 2}, {0, 3}, {0, 4}]

      [edge_west] = edges_from(board, {0, 4})
      assert edge_west.direction == :west
      assert edge_west.to == {0, 0}
      assert edge_west.path == [{0, 3}, {0, 2}, {0, 1}, {0, 0}]
    end

    test "nodes separated by vertical edge characters" do
      raw = """
      S
      |
      |
      X
      """

      board = Board.parse("v", raw, StyleS_X_Dash_Pipe)

      [edge] = edges_from(board, {0, 0})
      assert edge.direction == :south
      assert edge.to == {3, 0}
      assert edge.path == [{1, 0}, {2, 0}, {3, 0}]
    end

    test "T-junction node has 3 outgoing edges" do
      # S---X---X
      #     |
      #     X
      raw = "S---X---X\n    |    \n    X    "

      board = Board.parse("t", raw, StyleS_X_Dash_Pipe)

      junction = {0, 4}
      assert length(edges_from(board, junction)) == 3
      assert Enum.sort(dirs(board, junction)) == [:east, :south, :west]
    end

    test "unknown characters are silently treated as decor" do
      # 🌲S---X🌲   — the trees aren't in style.ex but parser doesn't
      # care; they're decor.
      board = Board.parse("decor", "🌲S---X🌲", StyleS_X_Dash_Pipe)
      assert map_size(board.nodes) == 2
      assert board.start == {0, 1}
      [edge] = edges_from(board, {0, 1})
      assert edge.to == {0, 5}
    end

    test "effects on nodes carry through" do
      board = Board.parse("eff", "S-M-?-X", StyleWithEffects)

      assert board.nodes[{0, 0}].effect == nil
      assert board.nodes[{0, 2}].effect == :minigame
      assert board.nodes[{0, 4}].effect == :mystery
      assert board.nodes[{0, 6}].effect == nil
    end

    test "rectangular loop: every node has degree 2" do
      # S----X
      # |    |
      # |    |
      # X----X
      raw = "S----X\n|    |\n|    |\nX----X"

      board = Board.parse("loop", raw, StyleS_X_Dash_Pipe)

      assert map_size(board.nodes) == 4

      for pos <- [{0, 0}, {0, 5}, {3, 0}, {3, 5}] do
        assert length(edges_from(board, pos)) == 2,
               "expected node #{inspect(pos)} to have 2 edges, got #{length(edges_from(board, pos))}"
      end
    end

    test "node kind is preserved (start vs. node)" do
      board = Board.parse("kinds", "S-X", StyleS_X_Dash_Pipe)
      assert board.nodes[{0, 0}].kind == :start
      assert board.nodes[{0, 2}].kind == :node
    end
  end

  describe "edge orientation" do
    # An edge char of the wrong axis can't connect two nodes. Both
    # adjacent nodes will then have no outgoing edges, so the orphan
    # check fires first. Either error (orphan or dangling) is acceptable
    # for now — both indicate the same broken map.

    test "horizontal edge char between vertically-aligned nodes fails to parse" do
      raw = "S\n-\nX"

      assert_raise ParseError, ~r/orphan|dangling/, fn ->
        Board.parse("misaligned", raw, StyleS_X_Dash_Pipe)
      end
    end

    test "vertical edge char between horizontally-aligned nodes fails to parse" do
      raw = "S|X"

      assert_raise ParseError, ~r/orphan|dangling/, fn ->
        Board.parse("misaligned", raw, StyleS_X_Dash_Pipe)
      end
    end
  end

  describe "parse/3 — errors" do
    test "no start node raises" do
      assert_raise ParseError, ~r/no start node/, fn ->
        Board.parse("nostart", "X-X", StyleNoStart)
      end
    end

    test "multiple start nodes raise" do
      assert_raise ParseError, ~r/multiple start/, fn ->
        Board.parse("twostarts", "S-T", StyleTwoStarts)
      end
    end

    test "orphan node (no outgoing edges) raises" do
      # A standalone `S` with no edges anywhere.
      assert_raise ParseError, ~r/orphan/, fn ->
        Board.parse("orphan", "S", StyleS_X_Dash_Pipe)
      end
    end

    test "dangling edge char (no node on the far side) raises" do
      # S--- with nothing past the dashes
      assert_raise ParseError, ~r/dangling/, fn ->
        Board.parse("dangling", "S---", StyleS_X_Dash_Pipe)
      end
    end
  end

  describe "public_view/1" do
    test "returns a JSON-ready map with all expected keys" do
      board = Board.parse("pv", "S-X", StyleS_X_Dash_Pipe)
      view = Board.public_view(board)

      assert view.name == "pv"
      assert view.raw == "S-X"
      assert view.width == 3
      assert view.height == 1
      assert view.start == [0, 0]
      assert is_map(view.node_style)
      assert is_map(view.edge_style)
      assert is_map(view.decor_style)
    end

    test "stringifies atom keys and atom values inside style maps" do
      board = Board.parse("strs", "S-X", StyleS_X_Dash_Pipe)
      view = Board.public_view(board)

      assert view.node_style["S"] == %{"kind" => "start", "color" => "yellow"}
      assert view.node_style["X"] == %{"kind" => "node", "color" => "cyan"}
      assert view.edge_style["-"] == %{"axis" => "horizontal", "color" => "cyan"}
    end

    test "start position is a 2-element list, not a tuple" do
      board = Board.parse("st", "S-X", StyleS_X_Dash_Pipe)
      view = Board.public_view(board)
      assert is_list(view.start)
      assert length(view.start) == 2
    end
  end
end
