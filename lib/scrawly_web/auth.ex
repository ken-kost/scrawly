defmodule ScrawlyWeb.Auth do
  @moduledoc """
  Server-side identity for Hologram commands and server inits.

  Hologram 0.9.2 hands `command/3` its params straight from the request body, so
  identity must never come from params. Every command that acts on behalf of a
  user reads that user through this module, which only trusts the signed
  session (`"user_id"`, written at sign-in / guest creation).

  Server-only: call it from `init/3` and `command/3`, never from `action/3`.
  """

  require Logger

  import Hologram.Component, only: [put_action: 3]

  alias Hologram.Server
  alias Scrawly.Accounts

  @doc """
  The session user's id, or `nil` when the visitor has no account.
  """
  @spec user_id(Server.t()) :: term | nil
  def user_id(%Server{} = server), do: Server.get_session(server, :user_id)

  @doc """
  Loads the session user. Never raises.

  A missing session entry, an unknown id, and an id that isn't a valid UUID all
  count as `{:error, :unauthenticated}`.
  """
  @spec current_user(Server.t()) :: {:ok, %Accounts.User{}} | {:error, :unauthenticated}
  def current_user(%Server{} = server) do
    case user_id(server) do
      nil ->
        {:error, :unauthenticated}

      id ->
        case Accounts.get_user_by_id(id) do
          {:ok, %Accounts.User{} = user} -> {:ok, user}
          _nil_or_error -> {:error, :unauthenticated}
        end
    end
  rescue
    _ -> {:error, :unauthenticated}
  end

  @doc """
  A stable key for the caller: the session user id when there is one, otherwise
  `"anon:"` plus the first 16 hex chars of the SHA-256 of the Hologram session id
  (hashed because watcher ids are broadcast to the whole room). `nil` when there
  is neither, e.g. in a bare `%Hologram.Server{}`.
  """
  @spec actor_key(Server.t()) :: term | nil
  def actor_key(%Server{} = server) do
    case user_id(server) do
      nil -> anon_key(server.session_id)
      id -> id
    end
  end

  defp anon_key(nil), do: nil

  defp anon_key(session_id) do
    digest =
      :crypto.hash(:sha256, to_string(session_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "anon:" <> digest
  end

  @doc """
  Rejects a command: logs a warning and replies with a `:command_denied` action
  whose params are `command`, `reason` and any `extra` entries (e.g. the
  stroke commands' `op_seq`). Changes no state and queues no broadcast.
  """
  @spec deny(Server.t(), atom, atom, keyword) :: Server.t()
  def deny(%Server{} = server, command, reason, extra \\ []) when is_atom(reason) do
    Logger.warning(
      "command denied: #{inspect(command)} (#{inspect(reason)}) for #{inspect(actor_key(server))}"
    )

    put_action(server, :command_denied, Keyword.merge(extra, command: command, reason: reason))
  end
end
