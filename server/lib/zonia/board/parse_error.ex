defmodule Zonia.Board.ParseError do
  @moduledoc """
  Raised by `Zonia.Board.parse/3` for any structural problem in a board:
  unknown character, missing/duplicate start tile, orphan tile, dangling
  edge, invalid kind.
  """
  defexception [:message]
end
