defmodule Zonia.Board do
  @moduledoc """
  A parsed board. Built once on server boot from a `map.txt` plus a style
  module (see `Zonia.Boards.Style`).

  The graph's adjacency is **inferred** from the layout:

    * two cells classed `:tile` that share a 4-neighbour edge are
      bidirectionally connected,
    * a directional edge character (`:edge_east` etc.) between two tiles
      makes the connection one-way in the indicated direction,
    * `:decor` cells are ignored for graph purposes (purely visual).

  The struct also carries the raw text and the style map so a client can
  render the board character-for-character without ever needing the graph.
  """

  alias Zonia.Boards.Style

  @type pos :: {non_neg_integer(), non_neg_integer()}
  @type direction :: :north | :south | :east | :west

  @type tile :: %{
          char: String.t(),
          kind: :tile,
          effect: atom() | nil,
          color: atom() | nil,
          start: boolean(),
          outgoing: [{pos(), direction()}]
        }

  @type t :: %__MODULE__{
          name: String.t(),
          raw: String.t(),
          style: Style.t(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          tiles: %{pos() => tile()},
          start: pos()
        }

  defstruct [:name, :raw, :style, :width, :height, :tiles, :start]

  @doc """
  Parse a board from a raw map string and a style map.

  Raises `Zonia.Board.ParseError` on any structural problem — unknown
  character, missing/duplicate start tile, orphan tile, dangling edge, etc.
  """
  @spec parse(String.t(), String.t(), Style.t()) :: t()
  def parse(name, raw, style) when is_binary(raw) and is_map(style) do
    grid = grid_of(raw)
    height = length(grid)
    width = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    # Classify every cell. Raise on unknown chars.
    classified = classify(grid, style, name)

    # Collect tiles + find the start.
    tiles = build_tiles(classified, style)
    start = find_start(tiles, name)

    %__MODULE__{
      name: name,
      raw: raw,
      style: style,
      width: width,
      height: height,
      tiles: tiles,
      start: start
    }
  end

  @doc """
  Public-facing JSON-ready map for the client. Strips internal graph data;
  the client only needs raw text + style + start position.
  """
  @spec public_view(t()) :: map()
  def public_view(%__MODULE__{} = b) do
    %{
      name: b.name,
      raw: b.raw,
      style: stringify_style(b.style),
      width: b.width,
      height: b.height,
      start: tuple_to_list(b.start)
    }
  end

  ## ── parsing internals ───────────────────────────────────────────────────

  defp grid_of(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.graphemes/1)
  end

  defp classify(grid, style, name) do
    grid
    |> Enum.with_index()
    |> Enum.map(fn {row, r} ->
      Enum.with_index(row) |> Enum.map(fn {ch, c} -> {{r, c}, ch, lookup!(style, ch, name)} end)
    end)
  end

  defp lookup!(style, ch, board_name) do
    case Map.fetch(style, ch) do
      {:ok, entry} ->
        validate_entry!(entry, ch, board_name)
        entry

      :error ->
        raise __MODULE__.ParseError,
              "board #{inspect(board_name)}: unknown character #{inspect(ch)} not in style map"
    end
  end

  @valid_kinds [:tile, :edge_north, :edge_south, :edge_east, :edge_west, :decor]

  defp validate_entry!(entry, ch, board_name) do
    case Map.get(entry, :kind) do
      kind when kind in @valid_kinds ->
        :ok

      other ->
        raise __MODULE__.ParseError,
              "board #{inspect(board_name)}: char #{inspect(ch)} has invalid kind #{inspect(other)}"
    end
  end

  defp build_tiles(classified, style) do
    flat = List.flatten(classified)
    index = for {pos, ch, entry} <- flat, into: %{}, do: {pos, {ch, entry}}

    tile_positions =
      for {pos, _ch, %{kind: :tile}} <- flat, do: pos

    tiles =
      Enum.reduce(tile_positions, %{}, fn pos, acc ->
        {ch, entry} = Map.fetch!(index, pos)
        outgoing = compute_outgoing(pos, index)

        if outgoing == [] do
          raise __MODULE__.ParseError,
                "board: orphan tile at #{inspect(pos)} — no walkable neighbours"
        end

        tile = %{
          char: ch,
          kind: :tile,
          effect: Map.get(entry, :effect),
          color: Map.get(entry, :color),
          start: Map.get(entry, :start, false),
          outgoing: outgoing
        }

        Map.put(acc, pos, tile)
      end)

    validate_edge_dangling!(style, index)
    tiles
  end

  # For a tile at `pos`, find all reachable tiles.
  #
  # Rules:
  #   * Direct neighbour cell is `:tile` → bidirectional edge, add this
  #     direction.
  #   * Direct neighbour cell is a matching `:edge_<dir>` AND the cell on
  #     the far side of the edge is `:tile` → one-way edge in that
  #     direction.
  #   * Anything else (decor, wrong-direction arrow, out of bounds) → no
  #     edge.
  defp compute_outgoing(pos, index) do
    for {dir, step} <- direction_vectors(),
        result = check_edge(pos, dir, step, index),
        result != nil do
      result
    end
  end

  defp direction_vectors do
    [{:north, {-1, 0}}, {:south, {1, 0}}, {:east, {0, 1}}, {:west, {0, -1}}]
  end

  defp check_edge({r, c}, dir, {dr, dc}, index) do
    neighbour = {r + dr, c + dc}

    case Map.get(index, neighbour) do
      {_ch, %{kind: :tile}} ->
        {neighbour, dir}

      {_ch, %{kind: edge_kind}} ->
        if edge_kind == edge_of(dir) do
          far = {r + 2 * dr, c + 2 * dc}

          case Map.get(index, far) do
            {_ch, %{kind: :tile}} -> {far, dir}
            _ -> nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp edge_of(:north), do: :edge_north
  defp edge_of(:south), do: :edge_south
  defp edge_of(:east), do: :edge_east
  defp edge_of(:west), do: :edge_west

  # Every `:edge_<dir>` char must sit between two tile cells (or a tile
  # cell + another arrow — for chained one-ways — but for v1 we require
  # `tile, arrow, tile`). Raise on anything that doesn't.
  defp validate_edge_dangling!(_style, index) do
    Enum.each(index, fn
      {pos, {_ch, %{kind: kind}}}
      when kind in [:edge_north, :edge_south, :edge_east, :edge_west] ->
        validate_arrow!(pos, kind, index)

      _ ->
        :ok
    end)
  end

  defp validate_arrow!({r, c}, kind, index) do
    {dr, dc} = arrow_vector(kind)
    behind = {r - dr, c - dc}
    ahead = {r + dr, c + dc}

    case {Map.get(index, behind), Map.get(index, ahead)} do
      {{_, %{kind: :tile}}, {_, %{kind: :tile}}} ->
        :ok

      _ ->
        raise __MODULE__.ParseError,
              "board: dangling #{kind} arrow at #{inspect({r, c})} — must sit between two tiles"
    end
  end

  defp arrow_vector(:edge_north), do: {-1, 0}
  defp arrow_vector(:edge_south), do: {1, 0}
  defp arrow_vector(:edge_east), do: {0, 1}
  defp arrow_vector(:edge_west), do: {0, -1}

  defp find_start(tiles, name) do
    starts =
      tiles
      |> Enum.filter(fn {_pos, tile} -> tile.start end)
      |> Enum.map(fn {pos, _} -> pos end)

    case starts do
      [pos] ->
        pos

      [] ->
        raise __MODULE__.ParseError,
              "board #{inspect(name)}: no start tile (set `start: true` on exactly one tile entry)"

      many ->
        raise __MODULE__.ParseError,
              "board #{inspect(name)}: multiple start tiles at #{inspect(many)}"
    end
  end

  defp stringify_style(style) do
    Map.new(style, fn {ch, entry} ->
      stringified =
        Map.new(entry, fn
          {:kind, v} -> {"kind", Atom.to_string(v)}
          {:color, v} when is_atom(v) -> {"color", Atom.to_string(v)}
          {:effect, v} when is_atom(v) -> {"effect", Atom.to_string(v)}
          {:start, v} -> {"start", v}
          {k, v} -> {Atom.to_string(k), v}
        end)

      {ch, stringified}
    end)
  end

  defp tuple_to_list({a, b}), do: [a, b]
end
