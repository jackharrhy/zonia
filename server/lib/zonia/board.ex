defmodule Zonia.Board do
  @moduledoc """
  A parsed board. Built once on server boot from a `map.txt` and a style
  module (see `Zonia.Boards.Style`).

  The graph is **sparse**: nodes are vertices, edges are sequences of
  cells the player walks through between vertices. Anything that isn't
  a registered node or edge character is decor and ignored.

  Movement model: a die roll of `N` means walk `N` cells. Players sit on
  either a node cell or an edge cell. Branching only happens at nodes
  with 2+ outgoing edges.

  ## Adjacency rules

    * Two node cells immediately next to each other (4-neighbour): direct
      edge of cost 0 cells between them.
    * Node → edge-char of the matching axis → eventually another node →
      walkable edge.
    * Edge chars are walked until either a node is reached or a
      non-walkable cell is hit. The latter is a dangling edge and raises.
    * Edge cells are oriented: `-` is horizontal-only, `|` is
      vertical-only. Walking onto a vertical edge from a horizontal
      direction (or vice versa) ends the path.

  ## Failure modes

    * No start node, or more than one — raises.
    * A node with no outgoing edges — raises (orphan).
    * An edge char that doesn't sit on a walkable path between two
      nodes — raises (dangling edge).
  """

  @type pos :: {non_neg_integer(), non_neg_integer()}
  @type direction :: :north | :south | :east | :west

  @type edge :: %{
          to: pos(),
          direction: direction(),
          path: [pos()]
        }

  @type node_data :: %{
          char: String.t(),
          kind: atom(),
          effect: atom() | nil,
          color: atom() | nil,
          edges: [edge()]
        }

  @type t :: %__MODULE__{
          name: String.t(),
          raw: String.t(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          nodes: %{pos() => node_data()},
          start: pos(),
          node_style: %{String.t() => map()},
          edge_style: %{String.t() => map()},
          decor_style: %{String.t() => map()}
        }

  defstruct [
    :name,
    :raw,
    :width,
    :height,
    :nodes,
    :start,
    :node_style,
    :edge_style,
    :decor_style
  ]

  @doc """
  Parse a board from a raw map string and a style module.

  Raises `Zonia.Board.ParseError` on structural problems.
  """
  @spec parse(String.t(), String.t(), module()) :: t()
  def parse(name, raw, style_module) when is_binary(raw) and is_atom(style_module) do
    node_style = style_module.nodes()
    edge_style = style_module.edges()

    decor_style =
      if function_exported?(style_module, :decor, 0), do: style_module.decor(), else: %{}

    grid = grid_of(raw)
    height = length(grid)
    width = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    index = build_index(grid)
    node_positions = collect_nodes(index, node_style)
    nodes = build_graph(node_positions, index, node_style, edge_style, name)
    start = find_start(nodes, name)

    %__MODULE__{
      name: name,
      raw: raw,
      width: width,
      height: height,
      nodes: nodes,
      start: start,
      node_style: node_style,
      edge_style: edge_style,
      decor_style: decor_style
    }
  end

  @doc """
  Public-facing JSON-ready map for the client. The client gets the raw
  text plus per-class styling hints — enough to render the board
  character-for-character without knowing the graph.
  """
  @spec public_view(t()) :: map()
  def public_view(%__MODULE__{} = b) do
    %{
      name: b.name,
      raw: b.raw,
      width: b.width,
      height: b.height,
      start: pos_to_list(b.start),
      node_style: stringify_style(b.node_style),
      edge_style: stringify_style(b.edge_style),
      decor_style: stringify_style(b.decor_style)
    }
  end

  ## ── parsing internals ───────────────────────────────────────────────────

  defp grid_of(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.graphemes/1)
  end

  defp build_index(grid) do
    for {row, r} <- Enum.with_index(grid),
        {ch, c} <- Enum.with_index(row),
        into: %{},
        do: {{r, c}, ch}
  end

  defp collect_nodes(index, node_style) do
    for {pos, ch} <- index, Map.has_key?(node_style, ch), do: pos
  end

  defp build_graph(node_positions, index, node_style, edge_style, board_name) do
    node_set = MapSet.new(node_positions)

    nodes =
      Enum.reduce(node_positions, %{}, fn pos, acc ->
        ch = Map.fetch!(index, pos)
        meta = Map.fetch!(node_style, ch)

        edges = compute_edges(pos, index, node_set, edge_style)

        if edges == [] do
          raise __MODULE__.ParseError,
                "board #{inspect(board_name)}: orphan node #{inspect(ch)} at #{inspect(pos)} — no outgoing edges"
        end

        node_data = %{
          char: ch,
          kind: Map.fetch!(meta, :kind),
          effect: Map.get(meta, :effect),
          color: Map.get(meta, :color),
          edges: edges
        }

        Map.put(acc, pos, node_data)
      end)

    validate_no_dangling_edges!(index, node_set, edge_style, board_name)
    nodes
  end

  defp compute_edges(pos, index, node_set, edge_style) do
    for {dir, vector} <- direction_vectors(),
        edge = walk_edge(pos, dir, vector, index, node_set, edge_style),
        edge != nil do
      edge
    end
  end

  defp direction_vectors do
    [{:north, {-1, 0}}, {:south, {1, 0}}, {:east, {0, 1}}, {:west, {0, -1}}]
  end

  # Walk one step in `dir` from `from_pos`. If the neighbor is another
  # node, that's a direct edge with empty path. If it's an edge char of
  # the matching axis, keep walking until we hit a node or fail.
  defp walk_edge(from_pos, dir, {dr, dc}, index, node_set, edge_style) do
    next = {elem(from_pos, 0) + dr, elem(from_pos, 1) + dc}

    cond do
      MapSet.member?(node_set, next) ->
        %{to: next, direction: dir, path: [next]}

      is_walkable_edge?(next, dir, index, edge_style) ->
        case walk_along(next, dir, {dr, dc}, index, node_set, edge_style, [next]) do
          {:ok, dest, path} -> %{to: dest, direction: dir, path: Enum.reverse(path)}
          :dead_end -> nil
        end

      true ->
        nil
    end
  end

  defp walk_along(current, dir, {dr, dc}, index, node_set, edge_style, acc) do
    next = {elem(current, 0) + dr, elem(current, 1) + dc}

    cond do
      MapSet.member?(node_set, next) ->
        {:ok, next, [next | acc]}

      is_walkable_edge?(next, dir, index, edge_style) ->
        walk_along(next, dir, {dr, dc}, index, node_set, edge_style, [next | acc])

      true ->
        :dead_end
    end
  end

  defp is_walkable_edge?(pos, dir, index, edge_style) do
    case Map.get(index, pos) do
      nil ->
        false

      ch ->
        case Map.get(edge_style, ch) do
          %{axis: axis} -> axis_matches?(axis, dir)
          _ -> false
        end
    end
  end

  defp axis_matches?(:horizontal, dir), do: dir in [:east, :west]
  defp axis_matches?(:vertical, dir), do: dir in [:north, :south]

  # Every edge char must sit on a walkable path between two nodes. Any
  # edge cell that's not visited by `build_graph` is dangling.
  defp validate_no_dangling_edges!(index, node_set, edge_style, board_name) do
    # Re-walk the graph collecting every edge cell that was used.
    used =
      for {pos, _} <- index,
          MapSet.member?(node_set, pos),
          {_dir, vector} <- direction_vectors(),
          {dr, dc} = vector,
          first_step = {elem(pos, 0) + dr, elem(pos, 1) + dc},
          not MapSet.member?(node_set, first_step),
          is_walkable_edge?(first_step, dir_of(vector), index, edge_style),
          path =
            walk_collect(first_step, dir_of(vector), vector, index, node_set, edge_style, [
              first_step
            ]),
          path != :dead_end,
          cell <- path,
          into: MapSet.new(),
          do: cell

    Enum.each(index, fn {pos, ch} ->
      cond do
        Map.has_key?(edge_style, ch) and not MapSet.member?(used, pos) ->
          raise __MODULE__.ParseError,
                "board #{inspect(board_name)}: dangling #{inspect(ch)} edge cell at #{inspect(pos)} — doesn't lie on a path between two nodes"

        true ->
          :ok
      end
    end)
  end

  defp dir_of({-1, 0}), do: :north
  defp dir_of({1, 0}), do: :south
  defp dir_of({0, 1}), do: :east
  defp dir_of({0, -1}), do: :west

  defp walk_collect(current, dir, {dr, dc}, index, node_set, edge_style, acc) do
    next = {elem(current, 0) + dr, elem(current, 1) + dc}

    cond do
      MapSet.member?(node_set, next) ->
        acc

      is_walkable_edge?(next, dir, index, edge_style) ->
        walk_collect(next, dir, {dr, dc}, index, node_set, edge_style, [next | acc])

      true ->
        :dead_end
    end
  end

  defp find_start(nodes, name) do
    starts =
      nodes
      |> Enum.filter(fn {_pos, node} -> node.kind == :start end)
      |> Enum.map(fn {pos, _} -> pos end)

    case starts do
      [pos] ->
        pos

      [] ->
        raise __MODULE__.ParseError,
              "board #{inspect(name)}: no start node (set `kind: :start` on exactly one node entry in style.ex)"

      many ->
        raise __MODULE__.ParseError,
              "board #{inspect(name)}: multiple start nodes at #{inspect(many)}"
    end
  end

  defp stringify_style(style) do
    Map.new(style, fn {ch, entry} ->
      stringified =
        Map.new(entry, fn
          {k, v} when is_atom(v) -> {Atom.to_string(k), Atom.to_string(v)}
          {k, v} -> {Atom.to_string(k), v}
        end)

      {ch, stringified}
    end)
  end

  defp pos_to_list({r, c}), do: [r, c]
end
