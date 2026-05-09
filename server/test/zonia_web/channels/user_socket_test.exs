defmodule ZoniaWeb.UserSocketTest do
  use ZoniaWeb.ChannelCase, async: true

  alias Zonia.Accounts
  alias ZoniaWeb.UserSocket

  describe "connect/3" do
    test "no key params → unauthenticated socket" do
      assert {:ok, socket} = connect(UserSocket, %{})
      assert socket.assigns.authenticated == false
      refute Map.has_key?(socket.assigns, :user_id)
    end

    test "empty-string key → unauthenticated socket" do
      assert {:ok, socket} = connect(UserSocket, %{"key" => ""})
      assert socket.assigns.authenticated == false
    end

    test "valid key → authenticated socket carrying user assigns" do
      {:ok, %{user: user, key: key}} = Accounts.register("boromir")
      assert {:ok, socket} = connect(UserSocket, %{"key" => key})
      assert socket.assigns.authenticated == true
      assert socket.assigns.user_id == user.id
      assert socket.assigns.user_name == "boromir"
    end

    test "invalid (but non-empty) key → connection refused" do
      assert :error = connect(UserSocket, %{"key" => "not-a-real-key"})
    end
  end

  describe "id/1" do
    test "is nil for unauthenticated sockets" do
      {:ok, socket} = connect(UserSocket, %{})
      assert UserSocket.id(socket) == nil
    end

    test "encodes the user id for authenticated sockets" do
      {:ok, %{user: user, key: key}} = Accounts.register("denethor")
      {:ok, socket} = connect(UserSocket, %{"key" => key})
      assert UserSocket.id(socket) == "user:#{user.id}"
    end
  end
end
