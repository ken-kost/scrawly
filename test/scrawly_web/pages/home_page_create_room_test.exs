defmodule ScrawlyWeb.Pages.HomePageCreateRoomTest do
  @moduledoc """
  `:create_room` takes client params, so forged ones (bad numbers, an unknown
  tone, missing keys, over-long fields) must fail validation and leave the
  server unchanged instead of raising.
  """
  use Scrawly.DataCase, async: false

  import Scrawly.RoomTestHelpers

  require Ash.Query

  alias Scrawly.Games.Room
  alias ScrawlyWeb.Pages.HomePage

  # What the create-room modal sends (HomePage action :create_room).
  @form %{
    name: "TEST forged",
    max_players: "6",
    word_count: "2",
    word_source: "ai",
    prompt: "ocean animals",
    round_duration: "120",
    round_multiplier: "3",
    ai_tone: "weird"
  }

  defp rooms_by(user), do: Room |> Ash.Query.filter(creator_id == ^user.id) |> Ash.read!()

  test "the modal's params create the room with parsed values" do
    user = create_user()

    result = HomePage.command(:create_room, @form, server_for(user))

    assert %{name: :join_room_with_user, params: %{room_id: room_id}} = result.next_action
    on_exit(fn -> stop_room(room_id) end)

    assert [room] = rooms_by(user)
    assert room.id == room_id

    assert %{
             max_players: 6,
             word_count: 2,
             word_source: :ai,
             prompt: "ocean animals",
             round_duration: 120,
             round_multiplier: 3,
             ai_tone: :weird
           } = room
  end

  test "forged params don't raise and create nothing" do
    user = create_user()
    server = server_for(user)

    forged = [
      %{@form | word_count: "abc"},
      %{@form | word_count: "2x"},
      %{@form | round_duration: "1e3"},
      %{@form | round_multiplier: "0"},
      %{@form | ai_tone: "nope"},
      %{@form | ai_tone: "Elixir.Kernel"},
      %{@form | ai_tone: 7},
      %{@form | max_players: "many"},
      %{@form | max_players: %{"x" => 1}},
      %{@form | name: nil},
      %{@form | name: String.duplicate("n", 41)},
      %{@form | prompt: String.duplicate("p", 201)},
      %{@form | word_count: "9"},
      Map.delete(@form, :name),
      %{}
    ]

    for params <- forged do
      assert HomePage.command(:create_room, params, server) == server,
             "#{inspect(params)} was not rejected"
    end

    assert rooms_by(user) == []
  end

  test "missing or nil optional values fall back to the Room's defaults" do
    user = create_user()

    for params <- [
          %{name: "TEST minimal"},
          %{@form | word_count: nil, ai_tone: nil, max_players: nil}
        ] do
      result = HomePage.command(:create_room, params, server_for(user))

      assert %{name: :join_room_with_user, params: %{room_id: room_id}} = result.next_action
      on_exit(fn -> stop_room(room_id) end)
    end

    assert [minimal] = Enum.filter(rooms_by(user), &(&1.name == "TEST minimal"))

    assert %{
             max_players: 12,
             word_count: 1,
             word_source: :local,
             prompt: nil,
             round_duration: 60,
             round_multiplier: 1,
             ai_tone: :fun
           } = minimal

    assert [%{max_players: 12, word_count: 1, ai_tone: :fun, word_source: :ai}] =
             Enum.filter(rooms_by(user), &(&1.name == "TEST forged"))
  end
end
