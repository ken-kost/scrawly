defmodule ScrawlyWeb.AuthController do
  use ScrawlyWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, _activity, user, _token) do
    conn
    |> store_in_session(user)
    |> put_session(:user_id, user.id)
    |> assign(:current_user, user)
    |> redirect(to: "/")
  end

  def failure(conn, _activity, _reason) do
    conn
    |> put_flash(:error, "Incorrect email or password")
    |> redirect(to: "/")
  end

  def sign_out(conn, _params) do
    conn
    |> clear_session(:scrawly)
    |> redirect(to: "/")
  end

  # Keeps a session that is already signed in (registered or guest): the
  # cookie is SameSite=Lax, so a plain link here must not switch a signed-in
  # user to a new guest, and repeat visits must not create rows. A session the
  # pages would sign out (revoked, expired or missing token) gets a new guest.
  # Hologram's identity (put_user_id) is synced by the page middleware on the
  # next request.
  def guest(conn, params) do
    if session_user?(conn) do
      redirect(conn, to: guest_return_to(params))
    else
      user = Scrawly.Accounts.register_as_guest!()

      conn
      |> store_in_session(user)
      |> put_session(:user_id, user.id)
      |> redirect(to: guest_return_to(params))
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

  defp guest_return_to(%{"return_to" => "/" <> _ = path}) do
    if String.starts_with?(path, "//"), do: "/", else: path
  end

  defp guest_return_to(_), do: "/"
end
