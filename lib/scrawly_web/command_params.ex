defmodule ScrawlyWeb.CommandParams do
  @moduledoc """
  Total readers for Hologram command params, plus the two standard denials.

  A command's name and params come from the client, and a forged request can
  send any term (not only a map, not only the keys our actions send). So every
  page, layout and component `command/3`:

    * reads params through these functions (never `params.key`, never a shape
      matched in the clause head, where a mismatch raises a
      FunctionClauseError or KeyError: an HTTP 500 whose report printed the
      server struct, see `ScrawlyWeb.LogRedactor`), and denies malformed ones
      with `deny_invalid/2`;
    * ends with a catch-all clause that denies with `deny_unknown/2`.

  Both deny through `ScrawlyWeb.Auth.deny/3`: a `:command_denied` reply, one
  log line without the params, nothing changed.

  Server-only.
  """

  alias Hologram.Server
  alias ScrawlyWeb.Auth

  @doc "The binary under `key`, or `nil` (missing, another type, or no map)."
  @spec string(term, atom) :: String.t() | nil
  def string(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def string(_params, _key), do: nil

  @doc "`{:ok, %{key => binary}}` when every key holds a binary, else `:error`."
  @spec strings(term, [atom]) :: {:ok, %{atom => String.t()}} | :error
  def strings(params, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case string(params, key) do
        nil -> {:halt, :error}
        value -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  @doc "`{:ok, uuid}` when `key` holds a UUID string, else `:error`."
  @spec uuid(term, atom) :: {:ok, String.t()} | :error
  def uuid(params, key) do
    with value when is_binary(value) <- string(params, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  @doc """
  The UUID strings in the list under `key`, at most `max` of them (anything
  else in the list is skipped); `[]` when `key` holds no list.
  """
  @spec uuids(term, atom, pos_integer) :: [String.t()]
  def uuids(params, key, max) when is_map(params) do
    case Map.get(params, key) do
      list when is_list(list) ->
        list
        |> Enum.take(max)
        |> Enum.flat_map(fn value ->
          case is_binary(value) and Ecto.UUID.cast(value) do
            {:ok, uuid} -> [uuid]
            _ -> []
          end
        end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  def uuids(_params, _key, _max), do: []

  @doc "Denies a command whose params don't have the expected shape."
  @spec deny_invalid(Server.t(), term) :: Server.t()
  def deny_invalid(%Server{} = server, command), do: Auth.deny(server, command, :invalid_params)

  @doc "Denies a command name the module doesn't handle (the catch-all clause)."
  @spec deny_unknown(Server.t(), term) :: Server.t()
  def deny_unknown(%Server{} = server, command), do: Auth.deny(server, command, :unknown_command)
end
