defmodule ScrawlyWeb.LobbyChat do
  @moduledoc """
  The home page's `:send_lobby_chat` command. Server-only.

  The name a line is shown under is decided here, never by the client: a
  signed-in user's username (`is_guest: false`), otherwise the session's
  `guest_<n>` nickname, created on the session's first line and kept in the
  session (`"guest_nickname"`), so it stays the same across reloads with the
  same cookie (`is_guest: true`). The line is stored and broadcast by
  `Scrawly.Games.LobbyChatServer`, rate-limited per
  `ScrawlyWeb.Auth.actor_key/1`.
  """

  import Hologram.Component, only: [put_action: 3]
  import Hologram.Server, only: [get_session: 2, put_session: 3]

  alias Hologram.Server
  alias Scrawly.Games.LobbyChatServer
  alias ScrawlyWeb.Auth

  @doc """
  Posts `params.message` to the lobby. A blank message does nothing. A
  rejected one (`:rate_limited`, `:no_sender`) replies `:lobby_chat_rejected`
  with the `reason` and the cleaned `message`.
  """
  @spec send_message(map, Server.t()) :: Server.t()
  def send_message(params, %Server{} = server) do
    case LobbyChatServer.clean_message(Map.get(params, :message)) do
      "" ->
        server

      text ->
        {username, is_guest, server} = display_name(server)

        case LobbyChatServer.add_message(Auth.actor_key(server), %{
               username: username,
               message: text,
               is_guest: is_guest
             }) do
          {:ok, _line} ->
            server

          {:error, reason} ->
            put_action(server, :lobby_chat_rejected, reason: reason, message: text)
        end
    end
  end

  @doc """
  `{username, is_guest, server}` for the session: the account's username, or
  the session's guest nickname (created and put in the session when missing).
  """
  @spec display_name(Server.t()) :: {String.t(), boolean, Server.t()}
  def display_name(%Server{} = server) do
    case Auth.current_user(server) do
      {:ok, %{username: username}} when is_binary(username) and username != "" ->
        {username, false, server}

      _signed_out ->
        case get_session(server, :guest_nickname) do
          nickname when is_binary(nickname) ->
            if guest_nickname?(nickname),
              do: {nickname, true, server},
              else: new_guest_nickname(server)

          _missing ->
            new_guest_nickname(server)
        end
    end
  end

  @doc "Whether `name` has the shape of a server-assigned guest nickname."
  @spec guest_nickname?(term) :: boolean
  def guest_nickname?(name) when is_binary(name), do: Regex.match?(~r/\Aguest_\d{1,20}\z/, name)
  def guest_nickname?(_name), do: false

  defp new_guest_nickname(server) do
    nickname = "guest_" <> Integer.to_string(System.unique_integer([:positive]))
    {nickname, true, put_session(server, :guest_nickname, nickname)}
  end
end
