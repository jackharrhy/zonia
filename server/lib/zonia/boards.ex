defmodule Zonia.Boards do
  @moduledoc """
  Loads and caches `Zonia.Board` structs from `priv/boards/<name>/`.
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
    style_module = style_module!(name)

    Board.parse(name, raw, style_module)
  end

  defp style_module!(name) do
    mod = String.to_atom("Elixir.Zonia.Boards.#{camelize(name)}.Style")

    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        cond do
          not function_exported?(mod, :nodes, 0) ->
            raise Board.ParseError,
                  "board #{inspect(name)}: #{inspect(mod)} doesn't export nodes/0"

          not function_exported?(mod, :edges, 0) ->
            raise Board.ParseError,
                  "board #{inspect(name)}: #{inspect(mod)} doesn't export edges/0"

          true ->
            mod
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
