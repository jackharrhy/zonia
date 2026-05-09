defmodule ZoniaWeb.ChannelCase do
  @moduledoc """
  Test helpers for working with `Phoenix.Channel`s in zonia.

  Each test gets its own DB sandbox; channel tests are not async-safe by
  default because PubSub broadcasts cross processes.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import ZoniaWeb.ChannelCase

      @endpoint ZoniaWeb.Endpoint
    end
  end

  setup tags do
    Zonia.DataCase.setup_sandbox(tags)
    :ok
  end
end
