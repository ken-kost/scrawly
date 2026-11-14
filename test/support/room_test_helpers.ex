defmodule Scrawly.RoomTestHelpers do
  @moduledoc """
  Helpers for tests that drive room commands against a live RoomServer.

  Use with `Scrawly.DataCase, async: false` so RoomServer processes share the
  SQL sandbox. `start_room/2` registers an `on_exit` that stops the RoomServer
  before the sandbox owner goes away.
  """

  import ExUnit.Assertions, only: [assert: 1, flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  require Ash.Query

  alias Scrawly.{Accounts, Games}
  alias Scrawly.Games.RoomServer

  @doc "Creates a non-guest user with a unique email and a `TEST…` username."
  def create_user do
    n = System.unique_integer([:positive])

    Ash.create!(
      Accounts.User,
      %{email: "test-#{n}@example.com", username: "TEST#{n}"},
      authorize?: false
    )
  end

  @doc """
  Creates a lobby room owned by `creator` (who joins it, as HomePage
  `:create_room` does) and starts its RoomServer.
  """
  def start_room(creator, attrs \\ %{}) do
    room =
      %{name: "TEST room", max_players: 4, creator_id: creator.id}
      |> Map.merge(attrs)
      |> Games.create_room!()

    Accounts.join_room!(creator, room.id)
    Games.join_room!(room.id, creator.id)
    {:ok, _pid} = RoomServer.ensure_started(room.id)
    on_exit(fn -> stop_room(room.id) end)

    room
  end

  @doc """
  Starts a game in `room` as `creator` (the room needs a second player) with
  `word` as the only choice, and commits it: the room is then in `:drawing`
  with `creator` as the drawer. Stops the round timer on exit. Returns the
  public state.
  """
  def start_drawing!(room, creator, word \\ "zzyzx") do
    {:ok, started} = RoomServer.start_game(room.id, creator.id, %{word_choices: [word]})
    on_exit(fn -> Games.stop_round_timer(started.game_id) end)
    {:ok, %{phase: :drawing} = state} = RoomServer.choose_word(room.id, creator.id, word)
    state
  end

  @doc "Stops the room's RoomServer if it is running."
  def stop_room(room_id) do
    case Registry.lookup(Scrawly.RoomRegistry, room_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Scrawly.RoomSupervisor, pid)
      [] -> :ok
    end
  end

  @doc """
  Stops the room's RoomServer and waits for its Registry entry to go (removed
  asynchronously), so the next `RoomServer.ensure_started/1` really starts
  (or fails to start) a new process.
  """
  def kill_room!(room) do
    stop_room(room.id)
    assert_room_stopped(room.id)
    assert_room_unregistered(room.id)
  end

  @doc "Waits up to ~500 ms for `RoomServer.room_exists?/1` to turn false."
  def assert_room_unregistered(room_id, tries \\ 50)

  def assert_room_unregistered(room_id, 0), do: flunk("#{room_id} is still registered")

  def assert_room_unregistered(room_id, tries) do
    if RoomServer.room_exists?(room_id) do
      Process.sleep(10)
      assert_room_unregistered(room_id, tries - 1)
    else
      :ok
    end
  end

  @doc """
  A command server struct for `user`'s session, as page middleware leaves it
  in `load: :id_only` mode (`:current_user_id` stashed, Hologram identity set;
  `ScrawlyWeb.Auth.current_user/1` loads the record when asked). For a real
  session token run through the middleware, see
  `Scrawly.SessionTestHelpers.signed_in_server/2`.
  """
  def server_for(user) do
    %Hologram.Server{
      session: %{"user_id" => user.id},
      session_id: "s-#{user.id}",
      stash: %{current_user_id: user.id},
      user_id: user.id
    }
  end

  @doc "A command server struct for a visitor with a session but no account."
  def anon_server(session_id \\ "anon-session-1") do
    %Hologram.Server{session: %{}, session_id: session_id}
  end

  def room_state!(room_id) do
    {:ok, state} = RoomServer.get_state(room_id)
    state
  end

  def reload_user!(user), do: Ash.get!(Accounts.User, user.id, authorize?: false)

  def reload_room!(room), do: Games.get_room_by_id!(room.id)

  @doc "Every Game row of the room, whatever its status."
  def games_for_room(%{id: room_id}) do
    Games.Game |> Ash.Query.filter(room_id == ^room_id) |> Ash.read!()
  end

  @doc """
  Asserts the RoomServer is gone. Uses a call rather than `room_exists?/1`,
  since the Registry entry is removed asynchronously after the process stops.
  """
  def assert_room_stopped(room_id) do
    assert RoomServer.get_state(room_id) == {:error, :not_found}
  end

  def chat_texts(state), do: Enum.map(state.chat_messages, & &1.message)

  @doc """
  True when `term` holds no struct at any depth (map keys and values, lists,
  tuples). Data that reaches the browser should be struct-free: Hologram
  makes the client load a code chunk for every struct type it receives.
  """
  def struct_free?(%_{}), do: false

  def struct_free?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> struct_free?(k) and struct_free?(v) end)

  def struct_free?(list) when is_list(list), do: Enum.all?(list, &struct_free?/1)
  def struct_free?(tuple) when is_tuple(tuple), do: struct_free?(Tuple.to_list(tuple))
  def struct_free?(_other), do: true

  @doc "A handful of local words of every difficulty, enough to pick word choices."
  def seed_test_words do
    for difficulty <- [:easy, :medium, :hard], i <- 1..4 do
      Ash.create!(Games.Word, %{
        text: "test#{difficulty}#{i}",
        difficulty: difficulty,
        word_count: 1
      })
    end
  end

  @doc """
  Sends `{:ai_call, action}` to the calling process whenever an Ash generic
  action in the Games domain starts (i.e. `generate_ai_words`).
  """
  def track_ai_calls do
    test_pid = self()
    id = "ai-calls-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:ash, :games, :action, :start],
      fn _event, _measurements, meta, _config -> send(test_pid, {:ai_call, meta[:action]}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
