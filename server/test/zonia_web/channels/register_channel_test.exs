defmodule ZoniaWeb.RegisterChannelTest do
  use ZoniaWeb.ChannelCase, async: true

  alias Zonia.Accounts
  alias ZoniaWeb.UserSocket

  defp unauthed_socket do
    {:ok, socket} = connect(UserSocket, %{})
    socket
  end

  defp authed_socket do
    {:ok, %{key: key}} = Accounts.register("eowyn")
    {:ok, socket} = connect(UserSocket, %{"key" => key})
    socket
  end

  describe "join" do
    test "unauthenticated sockets may join register:lobby" do
      assert {:ok, _reply, socket} =
               unauthed_socket()
               |> subscribe_and_join(ZoniaWeb.RegisterChannel, "register:lobby")

      assert socket.assigns.authenticated == false
    end

    test "authenticated sockets are forbidden from register:lobby" do
      assert {:error, %{reason: "already_registered"}} =
               authed_socket()
               |> subscribe_and_join(ZoniaWeb.RegisterChannel, "register:lobby")
    end
  end

  describe "register event" do
    setup do
      {:ok, _reply, socket} =
        unauthed_socket()
        |> subscribe_and_join(ZoniaWeb.RegisterChannel, "register:lobby")

      %{socket: socket}
    end

    test "happy path returns name and a fresh key", %{socket: socket} do
      ref = push(socket, "register", %{"name" => "merry"})
      assert_reply ref, :ok, %{name: "merry", key: key}
      assert is_binary(key) and byte_size(key) == 43

      # The minted key actually authenticates the user.
      assert {:ok, _user} = Accounts.authenticate(key)
    end

    test "duplicate name → name_taken", %{socket: socket} do
      {:ok, _} = Accounts.register("pippin")
      ref = push(socket, "register", %{"name" => "Pippin"})
      assert_reply ref, :error, %{reason: "name_taken"}
    end

    test "invalid name → name_invalid", %{socket: socket} do
      ref = push(socket, "register", %{"name" => "x"})
      assert_reply ref, :error, %{reason: "name_invalid"}
    end

    test "reserved name → name_reserved", %{socket: socket} do
      ref = push(socket, "register", %{"name" => "admin"})
      assert_reply ref, :error, %{reason: "name_reserved"}
    end

    test "missing/non-string payload → name_invalid", %{socket: socket} do
      ref = push(socket, "register", %{})
      assert_reply ref, :error, %{reason: "name_invalid"}
    end
  end
end
