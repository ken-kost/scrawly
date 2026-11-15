defmodule ScrawlyWeb.AuthController do
  @moduledoc """
  `GET /guest`, the "play as guest" link. Everything else about signing in
  and out runs as Hologram commands (AppLayout `:login` / `:register` /
  `:reset_password` / `:sign_out`, HomePage `:sign_in` / `:register`), which
  carry Hologram's CSRF check. The ash_authentication routes (`/auth/...`
  register, sign_in, sign_in_with_token and `GET /sign-out`) were never used
  by the pages and are gone: they bypassed the sign-in throttle, and a GET
  sign-out could be triggered by any other site.
  """

  use ScrawlyWeb, :controller

  alias Scrawly.Accounts.Throttle

  # Keeps a session that is already signed in (registered or guest): the
  # cookie is SameSite=Lax, so a plain link here must not switch a signed-in
  # user to a new guest, and repeat visits must not create rows. A session the
  # pages would sign out (revoked, expired or missing token) gets a new guest,
  # at most 20 per client IP per 10 minutes (`Scrawly.Accounts.Throttle`).
  # `return_to` is checked first, so a bad one creates nothing (it falls back
  # to "/"). Hologram's identity (put_user_id) is synced by the page
  # middleware on the next request.
  def guest(conn, params) do
    return_to = guest_return_to(params)

    cond do
      session_user?(conn) ->
        redirect(conn, to: return_to)

      match?({:ok, _ticket}, Throttle.reserve([{:guest_ip, ScrawlyWeb.ClientIp.from_conn(conn)}])) ->
        user = Scrawly.Accounts.register_as_guest!()

        conn
        |> put_session(:user_token, user.__metadata__.token)
        |> put_session(:user_id, user.id)
        |> redirect(to: return_to)

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          429,
          "Too many guest accounts from your network. Try again in a few minutes."
        )
    end
  end

  # The pages' session check (ScrawlyWeb.Auth.verify_session_token/2) plus an
  # existing row: an unknown or malformed id is no session user.
  defp session_user?(conn) do
    case ScrawlyWeb.Auth.verify_session_token(
           get_session(conn, :user_id),
           get_session(conn, :user_token)
         ) do
      {:ok, id, _token} -> match?({:ok, _user}, ScrawlyWeb.Auth.load_user(id))
      :error -> false
    end
  end

  # A local path made only of URL-safe characters ("/game/<id>", "/past-games",
  # "/?x=1"); anything else, e.g. "//host", "/\\host" or a tab (which
  # Phoenix's redirect/2 would raise on), becomes "/".
  defp guest_return_to(%{"return_to" => path}) when is_binary(path) do
    if Regex.match?(~r{\A/(?![/\\])[A-Za-z0-9\-._~/?=&]*\z}, path), do: path, else: "/"
  end

  defp guest_return_to(_params), do: "/"
end
