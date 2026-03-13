defmodule ScrawlyWeb.Components.ChatBox do
  use Hologram.Component

  prop :messages, :list, default: []
  prop :current_message, :string, default: ""
  prop :current_user_id, :string, default: nil
  prop :current_user_name, :string, default: nil
  prop :disabled, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="bg-white rounded-lg shadow-md flex flex-col h-96">
      <!-- Chat Header -->
      <div class="p-4 border-b border-gray-200">
        <h3 class="text-lg font-semibold text-black">Chat</h3>
      </div>

      <!-- Messages Area -->
      <div class="flex-1 overflow-y-auto p-4 space-y-2" id="chat-messages">
        <div $show={length(@messages) == 0} class="text-center py-8 text-gray-500">
          <p>No messages yet. Start the conversation!</p>
        </div>

        {%for msg <- @messages}
          <div class={[
            "p-2 rounded-lg",
            if(msg.type == "system", do: "bg-gray-100 text-gray-600 text-center text-sm italic",
            else: if(msg.is_correct_guess, do: "bg-green-100 border border-green-300",
            else: if(msg.user_id == @current_user_id, do: "bg-blue-100 ml-8",
            else: "bg-gray-100 mr-8")))
          ]}>
            {%if msg.type != "system"}
              <span class="font-semibold text-sm">{msg.username}:</span>
            {/if}
            <span class={if(msg.is_correct_guess, do: "font-bold text-green-700", else: "")}>{msg.message}</span>
            {%if msg.is_correct_guess}
              <span class="text-green-600 text-xs ml-2">✓ +{msg.points} pts</span>
            {/if}
          </div>
        {/for}
      </div>

      <!-- Message Input -->
      <div class="p-4 border-t border-gray-200">
        <div class="flex gap-2">
          <input
            type="text"
            placeholder="Type your guess..."
            class="flex-1 p-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100 disabled:cursor-not-allowed"
            value={@current_message}
            disabled={@disabled}
            $input="message_change"
            $keydown={:handle_keydown}>
          <button
            class="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white px-4 py-2 rounded-lg transition-colors disabled:cursor-not-allowed"
            disabled={@disabled || String.trim(@current_message) == ""}
            $click={:send_message}>
            Send
          </button>
        </div>
      </div>
    </div>
    """
  end

  def action(:message_change, %{event: %{value: message}}, component) do
    put_state(component, :temp_message, message)
  end

  def action(:send_message, _params, component) do
    message = component.state.temp_message || ""
    put_state(component, :temp_message, message)
  end

  def action(
        :send_message,
        _params,
        %{props: %{send_message_to_parent: send_to_parent}} = component
      )
      when is_function(send_to_parent) do
    message = component.state.temp_message || ""
    send_to_parent.(message)
    put_state(component, :temp_message, "")
  end

  def action(:send_message, _params, component) do
    put_state(component, :temp_message, "")
  end

  def action(:handle_keydown, %{"key" => "Enter"} = params, component) do
    action(:send_message, params, component)
  end

  def action(:handle_keydown, _params, component) do
    component
  end
end
