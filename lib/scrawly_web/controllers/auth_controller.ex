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

  # Keeps a session that already has a valid account (registered or guest):
  # the cookie is SameSite=Lax, so a plain link here must not switch a signed-in
  # user to a new guest, and repeat visits must not create rows.
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

  # An unknown or malformed id (not a UUID) is no session user.
  defp session_user?(conn) do
    case get_session(conn, :user_id) do
      id when is_binary(id) ->
        match?({:ok, %Scrawly.Accounts.User{}}, Scrawly.Accounts.get_user_by_id(id))

      _ ->
        false
    end
  end

  defp guest_return_to(%{"return_to" => "/" <> _ = path}) do
    if String.starts_with?(path, "//"), do: "/", else: path
  end

  defp guest_return_to(_), do: "/"
end
