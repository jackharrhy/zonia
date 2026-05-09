defmodule ZoniaWeb.RegisterChannel do
  @moduledoc """
  A throwaway channel that exists solely to expose `register` to unauthenticated
  sockets. Not a "place" in the world — it is the registration handshake.

  After a successful `register`, the client disconnects and reconnects with the
  new key. We do not promote the existing socket to authenticated.
  """
  use ZoniaWeb, :channel

  alias Zonia.Accounts

  @impl true
  def join("register:lobby", _payload, %{assigns: %{authenticated: false}} = socket) do
    {:ok, socket}
  end

  def join("register:lobby", _payload, _socket) do
    {:error, %{reason: "already_registered"}}
  end

  @impl true
  def handle_in("register", %{"name" => name}, socket) when is_binary(name) do
    case Accounts.register(name) do
      {:ok, %{user: user, key: key}} ->
        {:reply, {:ok, %{name: user.name, key: key}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
    end
  end

  def handle_in("register", _payload, socket) do
    {:reply, {:error, %{reason: "name_invalid"}}, socket}
  end
end
