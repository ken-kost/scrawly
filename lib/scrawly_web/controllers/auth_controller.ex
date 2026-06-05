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

  def guest(conn, params) do
    user = Scrawly.Accounts.register_as_guest!()

    conn
    |> store_in_session(user)
    |> put_session(:user_id, user.id)
    |> redirect(to: guest_return_to(params))
  end

  defp guest_return_to(%{"return_to" => "/" <> _ = path}) do
    if String.starts_with?(path, "//"), do: "/", else: path
  end

  defp guest_return_to(_), do: "/"
end
