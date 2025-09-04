defmodule ScrawlyWeb.Pages.HomePageTest do
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.HomePage

  describe "init/3" do
    test "initializes with default state" do
      component = HomePage.init(%{}, %Hologram.Component{}, nil)

      assert component.state.show_create_room == false
      assert component.state.new_room_name == ""
      assert is_list(component.state.rooms)
      assert length(component.state.rooms) > 0
    end
  end

  describe "action/3" do
    test "show_create_room sets show_create_room to true" do
      component = %Hologram.Component{state: %{show_create_room: false}}
      result = HomePage.action(:show_create_room, %{}, component)

      assert result.state.show_create_room == true
    end

    test "hide_create_room resets modal state" do
      component = %Hologram.Component{state: %{show_create_room: true, new_room_name: "test"}}
      result = HomePage.action(:hide_create_room, %{}, component)

      assert result.state.show_create_room == false
      assert result.state.new_room_name == "test"
    end

    test "update_room_name updates the room name" do
      component = %Hologram.Component{state: %{new_room_name: ""}}
      result = HomePage.action(:update_room_name, %{event: %{value: "New Room"}}, component)

      assert result.state.new_room_name == "New Room"
    end
  end
end
