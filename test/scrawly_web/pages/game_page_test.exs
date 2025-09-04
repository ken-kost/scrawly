defmodule ScrawlyWeb.Pages.GamePageTest do
  use ExUnit.Case, async: true

  alias ScrawlyWeb.Pages.GamePage

  describe "init/3" do
    test "initializes with room data" do
      params = %{room_id: "123"}
      component = GamePage.init(params, %Hologram.Component{}, nil)

      assert component.state.room_id == "123"
      assert component.state.room_name == "Room 123"
      assert is_list(component.state.players)
      assert component.state.new_message == ""
      assert is_list(component.state.chat_messages)
    end
  end

  describe "action/3" do
    test "update_message updates the message" do
      component = %Hologram.Component{state: %{new_message: ""}}
      result = GamePage.action(:update_message, %{event: %{value: "Hello"}}, component)

      assert result.state.new_message == "Hello"
    end

    test "send_message adds message and clears input" do
      component = %Hologram.Component{state: %{new_message: "Test message", chat_messages: []}}
      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == ""
      assert length(result.state.chat_messages) == 1
      assert hd(result.state.chat_messages).message == "Test message"
    end

    test "send_message ignores empty messages" do
      component = %Hologram.Component{state: %{new_message: "   ", chat_messages: []}}
      result = GamePage.action(:send_message, %{}, component)

      assert result.state.new_message == "   "
      assert length(result.state.chat_messages) == 0
    end
  end
end
