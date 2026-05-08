defmodule ZoniaWeb.Router do
  use ZoniaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ZoniaWeb do
    pipe_through :api
  end
end
