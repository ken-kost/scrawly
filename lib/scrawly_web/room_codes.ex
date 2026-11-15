defmodule ScrawlyWeb.RoomCodes do
  @moduledoc """
  Room codes that visitors type or open: Home's "have a code?" field
  (HomePage `:join_by_code`) and the short link `/r/:code`
  (`ScrawlyWeb.Pages.RoomLinkPage`).

  A code is 6 characters of the RFC 4648 base32 alphabet, A-Z and 2-7
  (`Scrawly.Games.Room.generate_code/0`): the digits 0, 1, 8 and 9 never
  appear, the letters O, I and B do. Input is trimmed, its spaces dropped and
  uppercased (`normalize/1`), so case doesn't matter.

  Input side, also run in the browser by HomePage's actions: `normalize/1`,
  `check/1`, `message/1`.

  Server only:

    * `lookup/2` finds the open room for a code. Lookups are capped per
      visitor (`Scrawly.Accounts.Throttle` policy `:room_code`, keyed by
      `ScrawlyWeb.Auth.actor_key/1`), and Home's field and the short link
      share the cap. Malformed input is refused before the cap and the
      database.
    * `entry_path/2` is where a found room is opened.
    * `put_notice/3` / `take_notice/1` carry a short link's failure to Home
      in the session.
  """

  alias Hologram.Server
  alias Scrawly.Accounts.Throttle
  alias ScrawlyWeb.Auth

  @length 6
  @alphabet String.graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

  @notice_key "room_code_notice"
  @notice_reasons [:not_found, :throttled]

  @type reason :: :empty | :length | :characters | :not_found | :throttled

  @doc "The length of a room code."
  @spec code_length() :: pos_integer
  def code_length, do: @length

  @doc """
  Typed or linked input as a code: trimmed, without spaces, uppercased.
  Anything but a string is `""`.
  """
  @spec normalize(term) :: String.t()
  def normalize(input) when is_binary(input) do
    input |> String.trim() |> String.replace(" ", "") |> String.upcase()
  end

  def normalize(_input), do: ""

  @doc "Whether a normalized code has the shape of a room code."
  @spec check(String.t()) :: :ok | {:error, :empty | :length | :characters}
  def check(""), do: {:error, :empty}

  def check(code) when is_binary(code) do
    cond do
      String.length(code) != @length -> {:error, :length}
      Enum.all?(String.graphemes(code), &(&1 in @alphabet)) -> :ok
      true -> {:error, :characters}
    end
  end

  def check(_code), do: {:error, :empty}

  @doc "The text shown for a refused code."
  @spec message(reason) :: String.t()
  def message(:empty), do: "type a room code"
  def message(:length), do: "room codes have #{@length} characters"
  def message(:characters), do: "room codes use letters and the digits 2-7"
  def message(:throttled), do: "too many tries, wait a minute"
  def message(_not_found), do: "no room with that code"

  @doc """
  The id of the room with this code (any case, spaces ignored) that hasn't
  ended. Counts one lookup for the visitor unless the input is malformed.
  """
  @spec lookup(Server.t(), term) :: {:ok, String.t()} | {:error, reason}
  def lookup(%Server{} = server, input) do
    code = normalize(input)

    with :ok <- check(code),
         {:ok, _ticket} <- Throttle.reserve([{:room_code, Auth.actor_key(server)}]),
         {:ok, %{id: id, status: status}} when status != :ended <-
           Scrawly.Games.get_room_by_code(code) do
      {:ok, id}
    else
      {:error, reason} when reason in [:empty, :length, :characters, :throttled] ->
        {:error, reason}

      _not_found_or_ended ->
        {:error, :not_found}
    end
  end

  @doc """
  Where a found room opens: its game page for a signed-in visitor (a guest
  too). A signed-out one first becomes a guest: `/guest` (AuthController)
  creates the guest and returns to the game page, a `return_to` it accepts.
  """
  @spec entry_path(Server.t(), String.t()) :: String.t()
  def entry_path(%Server{} = server, room_id) when is_binary(room_id) do
    game_path = "/game/" <> room_id

    if Auth.user_id(server),
      do: game_path,
      else: "/guest?" <> URI.encode_query(%{"return_to" => game_path})
  end

  @doc """
  Leaves a short link's failure in the session for Home's next `init/3`
  (`take_notice/1`): `:throttled`, or `:not_found` for anything else. A
  well-formed code goes with it, to show in the field again.
  """
  @spec put_notice(Server.t(), reason, term) :: Server.t()
  def put_notice(%Server{} = server, reason, input) do
    reason = if reason == :throttled, do: :throttled, else: :not_found
    code = normalize(input)
    code = if check(code) == :ok, do: code, else: ""

    Server.put_session(server, @notice_key, {reason, code})
  end

  @doc """
  Takes the notice `put_notice/3` left: `{server, nil}` when there is none,
  else the session key is deleted and the notice returned as
  `%{message: text, code: code_or_empty}`.
  """
  @spec take_notice(Server.t()) :: {Server.t(), %{message: String.t(), code: String.t()} | nil}
  def take_notice(%Server{} = server) do
    case Server.get_session(server, @notice_key) do
      nil ->
        {server, nil}

      notice ->
        {Server.delete_session(server, @notice_key), read_notice(notice)}
    end
  end

  # The session is signed, but only these shapes are shown.
  defp read_notice({reason, code}) when reason in @notice_reasons and is_binary(code) do
    %{message: message(reason), code: if(check(code) == :ok, do: code, else: "")}
  end

  defp read_notice(_notice), do: nil
end
