defmodule ZoniaWeb.WorldChannel do
  @moduledoc """
  The world. For v1: one big shared room (`world:lobby`).

  Events from client:
    * `say`: broadcast a chat line to everyone in the topic.

  Events to client:
    * `say`: `%{name, body, at}` — someone spoke.
    * `presence_state` / `presence_diff` — Phoenix.Presence roster.
  """
  use ZoniaWeb, :channel

  alias ZoniaWeb.Presence

  @max_body 500

  @impl true
  def join("world:lobby", _payload, %{assigns: %{authenticated: true}} = socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  def join("world:" <> _rest, _payload, _socket) do
    {:error, %{reason: "unauthenticated"}}
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(socket, to_string(socket.assigns.user_id), %{
        name: socket.assigns.user_name,
        online_at: System.system_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_in("say", %{"body" => body}, socket) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        {:reply, {:error, %{reason: "empty"}}, socket}

      String.length(trimmed) > @max_body ->
        {:reply, {:error, %{reason: "too_long"}}, socket}

      true ->
        broadcast!(socket, "say", %{
          name: socket.assigns.user_name,
          body: trimmed,
          at: System.system_time(:second)
        })

        {:reply, :ok, socket}
    end
  end

  def handle_in("say", _payload, socket) do
    {:reply, {:error, %{reason: "bad_payload"}}, socket}
  end
end
