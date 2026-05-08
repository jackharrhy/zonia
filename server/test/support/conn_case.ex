defmodule ZoniaWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ZoniaWeb.Endpoint

      use ZoniaWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import ZoniaWeb.ConnCase
    end
  end

  setup tags do
    Zonia.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
