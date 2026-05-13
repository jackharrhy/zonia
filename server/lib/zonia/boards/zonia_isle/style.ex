defmodule Zonia.Boards.ZoniaIsle.Style do
  @moduledoc """
  Side-channel style for the zonia-isle board.

  Frame characters (`╒══╕╘╛│═`) and background fill (`▒`) are pure decor:
  the parser ignores them, the client renders them with hints from
  `decor/0`. Only the named nodes and edge segments form the graph.
  """
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
  def decor do
    %{
      "▒" => %{color: :gray},
      "│" => %{color: :gray},
      "═" => %{color: :gray},
      "╒" => %{color: :gray},
      "╕" => %{color: :gray},
      "╘" => %{color: :gray},
      "╛" => %{color: :gray}
    }
  end
end
