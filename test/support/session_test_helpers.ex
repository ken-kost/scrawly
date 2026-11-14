defmodule Scrawly.SessionTestHelpers do
  @moduledoc """
  Real signed-in sessions for Hologram middleware, init and command tests:
  stored sign-in tokens, session maps as the browser carries them, and the
  page middleware chain run over them.
  """

  import ExUnit.Assertions, only: [assert: 1]

  alias Hologram.Server
  alias ScrawlyWeb.Auth
  alias ScrawlyWeb.Middleware.LoadCurrentUser

  @doc "Mints (and stores) a sign-in token for `user`, as a sign-in does."
  def mint_token!(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "user"})
    token
  end

  @doc """
  A request server struct whose session holds `user` and `token` (a freshly
  minted one by default), before any middleware ran.
  """
  def session_server(user, token \\ nil) do
    %Server{
      session: %{"user_id" => user.id, "user_token" => token || mint_token!(user)},
      session_id: "s-#{user.id}"
    }
  end

  @doc """
  `session_server/2` run through `LoadCurrentUser` with `opts` (`load: :user`
  by default), i.e. what a page's `init/3` or command receives.
  """
  def signed_in_server(user, opts \\ []) do
    user |> session_server() |> LoadCurrentUser.call(opts)
  end

  @doc "Runs `page`'s whole middleware chain (as Hologram does) over `server`."
  def run_page_middleware(page, server), do: Server.Middleware.run(server, page.__middleware__())

  @doc "The `{:put, value}` session writes recorded on `server`, as a map."
  def session_puts(server) do
    for {key, {:put, value}} <- Server.get_session_ops(server), into: %{}, do: {key, value}
  end

  @doc "The session keys `server` deletes."
  def session_deletes(server) do
    for {key, :delete} <- Server.get_session_ops(server), do: key
  end

  @doc """
  Asserts that the session `server` leaves behind signs `user` in: its
  `"user_id"` / `"user_token"` pass the pages' session check, and Hologram's
  identity is the same user. Returns the token.
  """
  def assert_signed_in_as(%Server{} = server, user) do
    assert server.session["user_id"] == user.id
    token = server.session["user_token"]
    assert {:ok, id, _row} = Auth.verify_session_token(server.session["user_id"], token)
    assert id == user.id
    assert server.user_id == user.id
    token
  end

  @doc "True when `token` still passes the pages' session check for `user`."
  def token_valid?(user, token),
    do: match?({:ok, _, _}, Auth.verify_session_token(user.id, token))

  @doc """
  Runs `fun` and returns `{result, queries}`, the Repo queries this process
  ran meanwhile as `{source_table, sql}` (other processes' are ignored).
  """
  def capture_queries(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:scrawly, :repo, :query],
      &__MODULE__.handle_query_event/4,
      %{pid: self(), ref: ref}
    )

    try do
      result = fun.()
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def handle_query_event(_event, _measurements, metadata, %{pid: pid, ref: ref}) do
    if self() == pid, do: send(pid, {ref, metadata[:source], metadata[:query]})
  end

  defp drain_queries(ref, acc) do
    receive do
      {^ref, source, sql} -> drain_queries(ref, [{source, sql} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "How many of `queries` (from `capture_queries/1`) are SELECTs on `table`."
  def selects(queries, table) do
    Enum.count(queries, fn {source, sql} ->
      source == table and String.starts_with?(sql, "SELECT")
    end)
  end
end
