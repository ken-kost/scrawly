defmodule Scrawly.Integration.MaxCapacityTest do
  use Scrawly.DataCase

  alias Scrawly.Games
  alias Scrawly.Accounts.User

  defp create_and_join_players(room, count) do
    for i <- 1..count do
      user =
        Ash.create!(
          User,
          %{email: "cap-p#{i}-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      user
      |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
      |> Ash.update!()
    end
  end

  describe "performance with maximum player capacity" do
    setup do
      {:ok, existing} = Games.get_all_words()
      Enum.each(existing, fn w -> Ash.destroy!(w) end)
      Scrawly.Games.Word.seed_words()

      {:ok, creator} =
        Ash.create(User, %{email: "cap-creator-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      %{creator: creator}
    end

    test "room holds exactly max_players (default 12)", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 12, name: "Full Room", creator_id: creator.id})

      players = create_and_join_players(room, 12)
      assert length(players) == 12

      # Verify room shows 12 players
      {:ok, loaded_room} = Games.get_room_by_id(room.id)
      assert length(loaded_room.players) == 12
    end

    test "13th player is rejected by Room join_room validation", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 12, name: "Full Room", creator_id: creator.id})

      _players = create_and_join_players(room, 12)

      # Create 13th player and attempt to join via Room's join_room action
      # (validation fails before PubSub fires, so this should work in tests)
      extra_user =
        Ash.create!(
          User,
          %{email: "cap-extra-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      result = Games.join_room(room.id, extra_user.id)
      assert {:error, _} = result
    end

    test "custom max_players (4) enforces its limit", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 4, name: "Small Room", creator_id: creator.id})

      _players = create_and_join_players(room, 4)

      {:ok, loaded} = Games.get_room_by_id(room.id)
      assert length(loaded.players) == 4

      # 5th player rejected
      extra =
        Ash.create!(
          User,
          %{email: "small-extra-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      assert {:error, _} = Games.join_room(room.id, extra.id)
    end

    test "game functions correctly with 12 players", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 12, name: "Full Game", creator_id: creator.id})

      players = create_and_join_players(room, 12)
      player_queue = Enum.map(players, & &1.id)

      {:ok, game} = Games.create_game(room.id, 3)

      # Round 1 with first player as drawer
      {:ok, game} = Games.start_round(game.id, List.first(player_queue))
      assert game.current_word != nil
      assert game.current_drawer_id == List.first(player_queue)

      # All non-drawers can "guess" (simulate score updates)
      non_drawers = Enum.drop(players, 1)
      assert length(non_drawers) == 11

      for p <- non_drawers do
        {:ok, _} = p |> Ash.Changeset.for_update(:update_score, %{score: 100}) |> Ash.update()
      end

      # Complete and move to next round
      {:ok, _} = Games.complete_round(game.id)
      {:ok, game} = Games.next_round(game.id)
      {:ok, game} = Games.start_round(game.id, Enum.at(player_queue, 1))

      assert game.current_round == 2
      assert game.current_drawer_id == Enum.at(player_queue, 1)
    end

    test "drawer rotation cycles through players with max rounds (10)", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 12, name: "Rotation Test", creator_id: creator.id})

      players = create_and_join_players(room, 12)
      player_queue = Enum.map(players, & &1.id)

      # Game max is 10 rounds, so test rotation through first 10 of 12 players
      {:ok, game} = Games.create_game(room.id, 10)

      drawer_history =
        Enum.reduce(1..10, {game, []}, fn round_num, {g, history} ->
          drawer_id = Enum.at(player_queue, round_num - 1)

          g =
            if round_num > 1 do
              {:ok, g} = Games.complete_round(g.id)
              {:ok, g} = Games.next_round(g.id)
              g
            else
              g
            end

          {:ok, g} = Games.start_round(g.id, drawer_id)
          {g, history ++ [g.current_drawer_id]}
        end)
        |> elem(1)

      # First 10 players each drew exactly once
      assert length(drawer_history) == 10
      assert length(Enum.uniq(drawer_history)) == 10
      # All drawn players are from the player queue
      assert MapSet.subset?(MapSet.new(drawer_history), MapSet.new(player_queue))
    end

    test "all 12 players appear in room player list (simulating Hologram state)", %{
      creator: creator
    } do
      {:ok, room} =
        Games.create_room(%{max_players: 12, name: "Player List Test", creator_id: creator.id})

      players = create_and_join_players(room, 12)

      # Simulate GamePage.init reading room data
      {:ok, loaded_room} = Games.get_room_by_id(room.id)

      # This is what GamePage puts into state: put_state(:players, room.players)
      state_players = loaded_room.players
      assert length(state_players) == 12

      # All players are present
      state_ids = MapSet.new(state_players, & &1.id)

      for p <- players do
        assert MapSet.member?(state_ids, p.id)
      end

      # can_start_game should be true (>= 2 players)
      can_start = length(state_players) >= 2
      assert can_start
    end

    test "when a player leaves, a new player can join", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 4, name: "Turnover Room", creator_id: creator.id})

      players = create_and_join_players(room, 4)

      # Verify full
      {:ok, loaded} = Games.get_room_by_id(room.id)
      assert length(loaded.players) == 4

      # One player leaves
      leaver = List.last(players)
      {:ok, leaver_fresh} = Ash.get(User, leaver.id)
      {:ok, _} = leaver_fresh |> Ash.Changeset.for_update(:leave_room, %{}) |> Ash.update()

      # Room now has 3 players
      {:ok, loaded} = Games.get_room_by_id(room.id)
      assert length(loaded.players) == 3

      # New player can join
      new_player =
        Ash.create!(
          User,
          %{email: "cap-new-#{System.unique_integer([:positive])}@test.com"},
          authorize?: false
        )

      {:ok, _} =
        new_player
        |> Ash.Changeset.for_update(:join_room, %{current_room_id: room.id})
        |> Ash.update()

      {:ok, loaded} = Games.get_room_by_id(room.id)
      assert length(loaded.players) == 4
    end

    test "min_players constraint (2) is enforced", %{creator: creator} do
      # Cannot create room with max_players < 2
      assert {:error, _} =
               Games.create_room(%{max_players: 1, name: "Too Small", creator_id: creator.id})
    end

    test "max_players constraint (12) is enforced", %{creator: creator} do
      # Cannot create room with max_players > 12
      assert {:error, _} =
               Games.create_room(%{max_players: 13, name: "Too Big", creator_id: creator.id})
    end

    test "scores work correctly with many players", %{creator: creator} do
      {:ok, room} =
        Games.create_room(%{max_players: 8, name: "Scoring Room", creator_id: creator.id})

      players = create_and_join_players(room, 8)

      {:ok, game} = Games.create_game(room.id, 3)
      {:ok, _} = Games.start_round(game.id, List.first(players).id)

      # All non-drawers score different amounts
      non_drawers = Enum.drop(players, 1)

      scored_players =
        non_drawers
        |> Enum.with_index(1)
        |> Enum.map(fn {p, i} ->
          score = i * 50

          {:ok, updated} =
            p |> Ash.Changeset.for_update(:update_score, %{score: score}) |> Ash.update()

          updated
        end)

      # Verify scores are all different and correctly assigned
      scores = Enum.map(scored_players, & &1.score)
      assert scores == [50, 100, 150, 200, 250, 300, 350]

      # ScoreBoard sorting works
      sorted = Enum.sort_by(scored_players, & &1.score, :desc)
      assert List.first(sorted).score == 350
      assert List.last(sorted).score == 50
    end
  end
end
