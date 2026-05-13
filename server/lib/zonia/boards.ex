defmodule Zonia.Boards do
  @moduledoc """
  Loads and caches `Zonia.Board` structs from `priv/boards/<name>/`.

  A board directory contains:

    * `map.txt` — the raw unicode art.
    * `style.ex` — a module implementing `Zonia.Boards.Style`, named by
      convention `Zonia.Boards.<CamelCasedName>.Style`.

  The list of available boards is hardcoded in config under
  `:zonia, :boards`. For v1 that's just `["zonia-isle"]`. To add a board:
  create the directory, add the name to config, write `map.txt` and
  `style.ex`.

  Boards are parsed eagerly via `load_all/0` on demand. The result is a
  flat map keyed by name. Parsing happens fresh each call — the
  application supervisor caches the result in its own state if it wants
  to (see `Zonia.Application`).
  """

  alias Zonia.Board

  @doc "Names of boards configured for this build."
  @spec names() :: [String.t()]
  def names do
    Application.get_env(:zonia, :boards, [])
  end

  @doc "Parse every configured board. Raises if any fails."
  @spec load_all() :: %{String.t() => Board.t()}
  def load_all do
    for name <- names(), into: %{}, do: {name, load!(name)}
  end

  @doc "Parse a single board by name. Raises if it's missing or malformed."
  @spec load!(String.t()) :: Board.t()
  def load!(name) when is_binary(name) do
    dir = Path.join([:code.priv_dir(:zonia), "boards", name])

    map_path = Path.join(dir, "map.txt")

    unless File.exists?(map_path) do
      raise Board.ParseError, "board #{inspect(name)}: missing #{map_path}"
    end

    raw = File.read!(map_path)
    style = style_module!(name).style()

    Board.parse(name, raw, style)
  end

  defp style_module!(name) do
    mod = String.to_atom("Elixir.Zonia.Boards.#{camelize(name)}.Style")

    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        if function_exported?(mod, :style, 0) do
          mod
        else
          raise Board.ParseError,
                "board #{inspect(name)}: #{inspect(mod)} doesn't export style/0"
        end

      {:error, reason} ->
        raise Board.ParseError,
              "board #{inspect(name)}: could not load style module #{inspect(mod)} (#{inspect(reason)})"
    end
  end

  defp camelize(name) do
    name
    |> String.split(["-", "_"])
    |> Enum.map_join("", &String.capitalize/1)
  end
end
