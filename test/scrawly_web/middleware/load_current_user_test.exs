defmodule ScrawlyWeb.Middleware.LoadCurrentUserTest do
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers, only: [create_user: 0]
  import Scrawly.SessionTestHelpers

  alias AshAuthentication.TokenResource
  alias Hologram.Server
  alias Scrawly.Accounts
  alias ScrawlyWeb.Auth
  alias ScrawlyWeb.Middleware.LoadCurrentUser

  @moduletag :capture_log

  defp run(server, opts \\ []), do: LoadCurrentUser.call(server, opts)

  defp assert_signed_out(result) do
    assert result.stash == %{current_user_id: nil, current_user: nil}
    assert result.user_id == nil
    assert result.status == nil
    refute Map.has_key?(result.session, "user_id")
    refute Map.has_key?(result.session, "user_token")
    result
  end

  defp jti(token) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
    jti
  end

  defp set_expires_in!(token, seconds) do
    Repo.query!(
      # expires_at is a UTC timestamp without time zone.
      "UPDATE tokens SET expires_at = (now() at time zone 'utc') + make_interval(secs => $2) " <>
        "WHERE jti = $1",
      [jti(token), seconds]
    )
  end

  describe "a valid session" do
    test "stashes the user and its id and syncs Hologram's identity" do
      user = create_user()
      server = session_server(user)

      result = run(server)

      assert result.stash.current_user_id == user.id
      assert %Accounts.User{id: id} = result.stash.current_user
      assert id == user.id
      assert result.user_id == user.id
      assert result.status == nil
      # A fresh token (14 days) is not renewed: nothing is written.
      assert Server.get_session_ops(result) == %{}
    end

    test "leaves an identity that already matches alone" do
      user = create_user()
      server = %{session_server(user) | user_id: user.id}

      assert run(server).user_id == user.id
    end

    test "replaces another user's stale Hologram identity" do
      user = create_user()
      server = %{session_server(user) | user_id: Ecto.UUID.generate()}

      assert run(server).user_id == user.id
    end

    test ":user mode runs one tokens lookup and one users SELECT" do
      user = create_user()
      server = session_server(user)

      {_result, queries} = capture_queries(fn -> run(server) end)

      assert selects(queries, "tokens") == 1
      assert selects(queries, "users") == 1
      assert length(queries) == 2
    end

    test ":id_only stashes only the id and runs no users query" do
      user = create_user()
      server = session_server(user)

      {result, queries} = capture_queries(fn -> run(server, load: :id_only) end)

      assert result.stash == %{current_user_id: user.id}
      assert result.user_id == user.id
      assert selects(queries, "tokens") == 1
      assert selects(queries, "users") == 0
      # Auth loads the record only when something asks for it.
      assert {:ok, %Accounts.User{id: id}} = Auth.current_user(result)
      assert id == user.id
    end

    test "an unknown load mode raises" do
      user = create_user()

      assert_raise ArgumentError, ~r/load: :user or load: :id_only/, fn ->
        run(session_server(user), load: :everything)
      end
    end
  end

  describe "renewal" do
    test "a token expiring within 7 days is replaced by a fresh stored one" do
      user = create_user()
      old = mint_token!(user)
      set_expires_in!(old, 2 * 24 * 60 * 60)

      result = run(session_server(user, old))

      new = session_puts(result)["user_token"]
      assert is_binary(new)
      refute new == old
      assert_signed_in_as(result, user)
      assert result.stash.current_user.id == user.id

      # The new token runs the full 14 days, so the next request renews nothing.
      assert Server.get_session_ops(run(session_server(user, new))) == %{}
    end

    test "a token with more than 7 days left is kept" do
      user = create_user()
      token = mint_token!(user)
      set_expires_in!(token, LoadCurrentUser.renew_within_seconds() + 3600)

      assert Server.get_session_ops(run(session_server(user, token))) == %{}
    end

    test ":id_only never renews (it has no user record)" do
      user = create_user()
      token = mint_token!(user)
      set_expires_in!(token, 60)

      result = run(session_server(user, token), load: :id_only)

      assert result.stash.current_user_id == user.id
      assert Server.get_session_ops(result) == %{}
    end
  end

  describe "an invalid session with a user_id" do
    setup do
      user = create_user()

      base = %{
        "dark_mode" => true,
        "accent_color" => "orange",
        "watch_mode" => "yes"
      }

      %{user: user, base: base}
    end

    defp invalid_server(base, user_id, token, hologram_user_id) do
      session =
        base
        |> Map.put("user_id", user_id)
        |> then(&if(token, do: Map.put(&1, "user_token", token), else: &1))

      %Server{session: session, session_id: "s1", user_id: hologram_user_id}
    end

    defp assert_cleared(result, base) do
      assert_signed_out(result)
      assert "user_id" in session_deletes(result)
      # The theme keys and watch_mode stay.
      assert result.session == base
    end

    test "missing token", %{user: user, base: base} do
      invalid_server(base, user.id, nil, user.id) |> run() |> assert_cleared(base)
    end

    test "another user's token", %{user: user, base: base} do
      other_token = mint_token!(create_user())

      result = invalid_server(base, user.id, other_token, user.id) |> run()

      assert_cleared(result, base)
      assert "user_token" in session_deletes(result)
    end

    test "a garbage token", %{user: user, base: base} do
      invalid_server(base, user.id, "not-a-jwt", nil) |> run() |> assert_cleared(base)
    end

    test "revoked via TokenResource.Actions.revoke/2", %{user: user, base: base} do
      token = mint_token!(user)
      :ok = TokenResource.Actions.revoke(Accounts.Token, token)

      invalid_server(base, user.id, token, user.id) |> run() |> assert_cleared(base)
    end

    test "revoked via log_out_everywhere", %{user: user, base: base} do
      token = mint_token!(user)
      strategy = AshAuthentication.Info.strategy!(Accounts.User, :log_out_everywhere)
      :ok = AshAuthentication.Strategy.action(strategy, :log_out_everywhere, %{user: user})

      invalid_server(base, user.id, token, user.id) |> run() |> assert_cleared(base)
    end

    test "expired", %{user: user, base: base} do
      token = mint_token!(user)
      set_expires_in!(token, -60)

      invalid_server(base, user.id, token, user.id) |> run() |> assert_cleared(base)
    end

    test "the legacy \"Watcher\" id", %{base: base} do
      invalid_server(base, "Watcher", nil, nil) |> run() |> assert_cleared(base)
    end

    test "a valid token of a user that no longer exists", %{base: base} do
      ghost = create_user()
      token = mint_token!(ghost)
      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(ghost.id)])

      result = invalid_server(base, ghost.id, token, ghost.id) |> run()
      assert_cleared(result, base)

      # :id_only can't tell (no users query): the token decides.
      assert run(invalid_server(base, ghost.id, token, nil), load: :id_only).stash ==
               %{current_user_id: ghost.id}
    end

    test "a copy of a signed-out cookie stays signed out", %{user: user, base: base} do
      token = mint_token!(user)
      copied = invalid_server(base, user.id, token, user.id)
      assert run(copied).stash.current_user_id == user.id

      # /sign-out revokes the session's token (AuthController.sign_out).
      :ok = TokenResource.Actions.revoke(Accounts.Token, token)

      copied |> run() |> assert_cleared(base)
    end
  end

  describe "no session user" do
    test "stashes nils and writes nothing" do
      result = run(%Server{session: %{"dark_mode" => true}, session_id: "s1"})

      assert_signed_out(result)
      assert Server.get_session_ops(result) == %{}
      assert result.session == %{"dark_mode" => true}
    end

    test "clears a leftover Hologram identity" do
      result = run(%Server{session: %{}, user_id: Ecto.UUID.generate()})

      assert_signed_out(result)
    end

    test "runs no query" do
      {_result, queries} = capture_queries(fn -> run(%Server{session: %{}}) end)
      assert queries == []
    end
  end
end
