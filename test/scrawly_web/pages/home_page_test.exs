defmodule ScrawlyWeb.Pages.HomePageTest do
  use ExUnit.Case, async: false

  alias ScrawlyWeb.Pages.HomePage

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Scrawly.Repo)
  end

  describe "init/3" do
    test "initializes with default state" do
      server = %Hologram.Server{session: %{}}
      {component, _server} = HomePage.init(%{}, %Hologram.Component{}, server)

      assert component.state.show_create_room == false
      assert component.state.creating_room? == false
      assert is_list(component.state.rooms)
    end
  end

  describe "action/3" do
    test "show_create_room sets show_create_room to true" do
      component = %Hologram.Component{state: %{show_create_room: false, create_room_form: 0}}
      result = HomePage.action(:show_create_room, %{}, component)

      assert result.state.show_create_room == true
    end

    test "hide_create_room closes the form and forgets its errors" do
      component = %Hologram.Component{
        state: %{show_create_room: true, creating_room?: true, create_room_errors: %{name: "x"}}
      }

      result = HomePage.action(:hide_create_room, %{}, component)

      assert result.state.show_create_room == false
      assert result.state.creating_room? == false
      assert result.state.create_room_errors == %{}
    end

    test "the form's fields live in RoomSettingsForm, not here" do
      for name <- [:update_room_name, :update_max_players, :set_answer_kind, :set_word_source] do
        assert_raise FunctionClauseError, fn ->
          HomePage.action(name, %{value: "x", event: %{value: "x"}}, %Hologram.Component{})
        end
      end
    end
  end
end
