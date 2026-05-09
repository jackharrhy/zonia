defmodule ZoniaWeb.WorldChannelTest do
  # async: false — Phoenix.Presence runs in a shared registry, so concurrent
  # tests joining the same topic see each other's presence diffs.
  use ZoniaWeb.ChannelCase, async: false

  alias Zonia.Accounts
  alias ZoniaWeb.{Presence, UserSocket}

  defp join_world(name) do
    {:ok, %{user: user, key: key}} = Accounts.register(name)
    {:ok, socket} = connect(UserSocket, %{"key" => key})
    {:ok, _reply, socket} = subscribe_and_join(socket, ZoniaWeb.WorldChannel, "world:lobby")
    %{user: user, socket: socket}
  end

  describe "join" do
    test "authenticated sockets may join world:lobby" do
      {:ok, %{key: key}} = Accounts.register("samwise")
      {:ok, socket} = connect(UserSocket, %{"key" => key})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, ZoniaWeb.WorldChannel, "world:lobby")
    end

    test "unauthenticated sockets are refused" do
      {:ok, socket} = connect(UserSocket, %{})

      assert {:error, %{reason: "unauthenticated"}} =
               subscribe_and_join(socket, ZoniaWeb.WorldChannel, "world:lobby")
    end

    test "join pushes presence_state to the joiner" do
      {:ok, %{user: user, key: key}} = Accounts.register("treebeard")
      {:ok, socket} = connect(UserSocket, %{"key" => key})
      {:ok, _reply, _socket} = subscribe_and_join(socket, ZoniaWeb.WorldChannel, "world:lobby")

      user_id_str = to_string(user.id)
      assert_push "presence_state", %{^user_id_str => %{metas: [%{name: "treebeard"}]}}
    end

    test "joining tracks the user in Presence" do
      %{user: user} = join_world("faramir")

      list = Presence.list("world:lobby")
      user_id_str = to_string(user.id)
      assert %{metas: [%{name: "faramir"}]} = Map.fetch!(list, user_id_str)
    end
  end

  describe "say" do
    setup do
      Map.put(join_world("arwen"), :body, "hello world")
    end

    test "broadcasts to subscribers", %{socket: socket, body: body} do
      ref = push(socket, "say", %{"body" => body})
      assert_reply ref, :ok

      assert_broadcast "say", %{name: "arwen", body: ^body, at: at}
      assert is_integer(at)
    end

    test "trims whitespace before broadcasting", %{socket: socket} do
      ref = push(socket, "say", %{"body" => "   hi   "})
      assert_reply ref, :ok
      assert_broadcast "say", %{body: "hi"}
    end

    test "rejects empty / whitespace-only messages", %{socket: socket} do
      ref = push(socket, "say", %{"body" => ""})
      assert_reply ref, :error, %{reason: "empty"}

      ref2 = push(socket, "say", %{"body" => "   "})
      assert_reply ref2, :error, %{reason: "empty"}
    end

    test "rejects messages over 500 chars", %{socket: socket} do
      ref = push(socket, "say", %{"body" => String.duplicate("a", 501)})
      assert_reply ref, :error, %{reason: "too_long"}
    end

    test "accepts a message exactly 500 chars long", %{socket: socket} do
      body = String.duplicate("a", 500)
      ref = push(socket, "say", %{"body" => body})
      assert_reply ref, :ok
      assert_broadcast "say", %{body: ^body}
    end

    test "rejects bad payload shape", %{socket: socket} do
      ref = push(socket, "say", %{"body" => 123})
      assert_reply ref, :error, %{reason: "bad_payload"}

      ref2 = push(socket, "say", %{})
      assert_reply ref2, :error, %{reason: "bad_payload"}
    end
  end
end
