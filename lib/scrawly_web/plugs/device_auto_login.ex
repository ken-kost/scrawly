defmodule ScrawlyWeb.Plugs.DeviceAutoLogin do
  @moduledoc """
  Auto sign-in plug for the Mob thin-client.

  When a request arrives carrying `?device_id=<uuid>` and no session user
  is currently set, this plug calls `Scrawly.Accounts.register_with_device_id/1`
  (an upsert keyed on the unique device_id identity), seeds the session with
  the new user's id + auth token, and redirects to the same request path
  with the `device_id` parameter stripped so it doesn't leak into shared
  URLs or browser history.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with nil <- get_session(conn, :user_id),
         device_id when is_binary(device_id) <- Map.get(conn.query_params, "device_id"),
         {:ok, uuid} <- Ecto.UUID.cast(device_id),
         {:ok, user} <- Scrawly.Accounts.register_with_device_id(uuid, authorize?: false) do
      conn
      |> put_session(:user_id, user.id)
      |> put_session(:user_token, user.__metadata__.token)
      |> configure_session(renew: true)
      |> redirect(to: strip_device_id(conn))
      |> halt()
    else
      _ -> conn
    end
  end

  defp strip_device_id(conn) do
    remaining = Map.delete(conn.query_params, "device_id")

    case URI.encode_query(remaining) do
      "" -> conn.request_path
      qs -> conn.request_path <> "?" <> qs
    end
  end
end
