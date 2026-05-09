defmodule Zonia.AccountsTest do
  use Zonia.DataCase, async: true

  alias Zonia.Accounts
  alias Zonia.Accounts.User

  describe "register/1" do
    test "mints a user and a key on the happy path" do
      assert {:ok, %{user: %User{} = user, key: key}} = Accounts.register("Gandalf")

      assert user.name == "Gandalf"
      assert user.name_normalized == "gandalf"
      assert is_binary(key)
      # 32 random bytes, base64url, no padding → 43 chars
      assert byte_size(key) == 43
      # The raw key is never persisted; only its hash.
      refute user.key_hash == key
    end

    test "stores a sha256 hex digest of the key" do
      {:ok, %{user: user, key: key}} = Accounts.register("Aragorn")
      expected = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
      assert user.key_hash == expected
    end

    test "names are unique case-insensitively" do
      {:ok, _} = Accounts.register("Frodo")
      assert {:error, :name_taken} = Accounts.register("frodo")
      assert {:error, :name_taken} = Accounts.register("FRODO")
      assert {:error, :name_taken} = Accounts.register("Frodo")
    end

    test "rejects names that are too short" do
      assert {:error, :name_invalid} = Accounts.register("a")
      assert {:error, :name_invalid} = Accounts.register("")
    end

    test "rejects names that are too long" do
      assert {:error, :name_invalid} = Accounts.register(String.duplicate("a", 25))
    end

    test "accepts names at the length boundaries" do
      assert {:ok, _} = Accounts.register("ab")
      assert {:ok, _} = Accounts.register(String.duplicate("z", 24))
    end

    test "rejects names with invalid characters" do
      assert {:error, :name_invalid} = Accounts.register("hello world")
      assert {:error, :name_invalid} = Accounts.register("hi!")
      assert {:error, :name_invalid} = Accounts.register("nñ")
      assert {:error, :name_invalid} = Accounts.register("with.dot")
    end

    test "accepts the full allowed charset" do
      assert {:ok, _} = Accounts.register("a-b_c-1_2")
    end

    test "rejects reserved names regardless of case" do
      assert {:error, :name_reserved} = Accounts.register("admin")
      assert {:error, :name_reserved} = Accounts.register("Admin")
      assert {:error, :name_reserved} = Accounts.register("SYSTEM")
      assert {:error, :name_reserved} = Accounts.register("zonia")
    end

    test "rejects non-binary input" do
      assert {:error, :name_invalid} = Accounts.register(nil)
      assert {:error, :name_invalid} = Accounts.register(123)
    end

    test "two registrations produce different keys" do
      {:ok, %{key: k1}} = Accounts.register("alice")
      {:ok, %{key: k2}} = Accounts.register("bob")
      refute k1 == k2
    end
  end

  describe "authenticate/1" do
    setup do
      {:ok, %{user: user, key: key}} = Accounts.register("legolas")
      %{user: user, key: key}
    end

    test "returns the user for the right key", %{user: user, key: key} do
      assert {:ok, found} = Accounts.authenticate(key)
      assert found.id == user.id
      assert found.name == "legolas"
    end

    test "returns :error for an unknown key" do
      assert :error = Accounts.authenticate("not-a-real-key")
    end

    test "returns :error for empty / nil / non-string input" do
      assert :error = Accounts.authenticate("")
      assert :error = Accounts.authenticate(nil)
      assert :error = Accounts.authenticate(12_345)
    end

    test "key collisions across users do not authenticate the wrong one", %{key: key} do
      {:ok, %{key: other_key}} = Accounts.register("gimli")
      refute key == other_key
      assert {:ok, u1} = Accounts.authenticate(key)
      assert {:ok, u2} = Accounts.authenticate(other_key)
      refute u1.id == u2.id
    end
  end
end
