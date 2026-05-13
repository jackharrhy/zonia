defmodule Mix.Tasks.Zonia.DumpBoard do
  @shortdoc "Dump a parsed board's public view as JSON."

  @moduledoc """
  Loads a configured board, runs it through `Zonia.Board.public_view/1`,
  and writes the result as pretty-printed JSON to `tmp/boards/<name>.json`
  at the repo root.

  ## Usage

      mix zonia.dump_board zonia-isle

  The board name must be one of those listed in
  `Zonia.Boards.names/0` (configured under `:zonia, :boards`).

  The output path is `../tmp/boards/<name>.json` relative to the
  server's cwd, i.e. `<repo>/tmp/boards/<name>.json`.
  """

  use Mix.Task

  @app :zonia
  @output_dir "../tmp/boards"

  @impl Mix.Task
  def run(args) do
    load_app()

    case args do
      [name] ->
        dump(name)

      [] ->
        usage_error("missing board name argument")

      _ ->
        usage_error("expected exactly one argument, got #{length(args)}")
    end
  end

  defp dump(name) do
    available = Zonia.Boards.names()

    unless name in available do
      IO.puts(
        :stderr,
        "error: unknown board #{inspect(name)}. Available boards: #{inspect(available)}"
      )

      exit({:shutdown, 1})
    end

    board = Zonia.Boards.load!(name)
    json = board |> Zonia.Board.public_view() |> Jason.encode!(pretty: true)

    File.mkdir_p!(@output_dir)
    path = Path.join(@output_dir, "#{name}.json")
    File.write!(path, json)

    bytes = byte_size(json)
    IO.puts("→ wrote #{path} (#{bytes} bytes)")
  end

  defp usage_error(reason) do
    IO.puts(:stderr, "error: #{reason}")
    IO.puts(:stderr, "")
    IO.puts(:stderr, "Usage: mix zonia.dump_board <board-name>")
    IO.puts(:stderr, "")
    IO.puts(:stderr, "Available boards: #{inspect(Zonia.Boards.names())}")
    exit({:shutdown, 1})
  end

  defp load_app do
    Application.ensure_loaded(@app)
  end
end
