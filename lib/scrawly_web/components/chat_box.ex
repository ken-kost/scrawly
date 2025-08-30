defmodule ScrawlyWeb.Components.ChatBox do
  use Hologram.Component

  prop :messages, :list, default: []
  prop :current_message, :string, default: ""
  prop :current_user_id, :string, default: nil
  prop :disabled, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="bg-white rounded-lg shadow-md flex flex-col h-96">
      <!-- Chat Header -->
      <div class="p-4 border-b border-gray-200">
        <h3 class="text-lg font-semibold text-black">Chat</h3>
      </div>

      <!-- Messages Area -->
      <div class="flex-1 overflow-y-auto p-4 space-y-3" id="chat-messages">
        <div $show={length(@messages) == 0} class="text-center py-8 text-gray-500">
          <p>No messages yet. Start the conversation!</p>
        </div>

                <div class="text-center py-4 text-gray-600">
          <p>{length(@messages)} message(s)</p>
          <p class="text-sm mt-2">ChatBox component loaded successfully!</p>
        </div>
      </div>

      <!-- Message Input -->
      <div class="p-4 border-t border-gray-200">
        <div class="flex gap-2">
          <input
            type="text"
                          placeholder="Type a message..."
            class="flex-1 p-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:bg-gray-100 disabled:cursor-not-allowed"
            value={@current_message}
            disabled={@disabled}
            $input="message_change"
            $keydown="handle_keydown">
          <button
            class="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white px-4 py-2 rounded-lg transition-colors disabled:cursor-not-allowed"
            disabled={@disabled || String.trim(@current_message) == ""}
            $click="send_message">
            Send
          </button>
        </div>
      </div>
    </div>
    """
  end

  def action("message_change", %{"value" => message}, component) do
    # For now, just update local state - in a real app this would communicate with parent
    put_state(component, :temp_message, message)
  end

  def action("send_message", _params, component) do
    # For now, just clear the message - in a real app this would send to parent/server
    put_state(component, :temp_message, "")
  end

  def action("handle_keydown", %{"key" => "Enter"} = params, component) do
    action("send_message", params, component)
  end

  def action("handle_keydown", _params, component) do
    component
  end

  # Helper function to format timestamp
  defp format_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} ->
        dt
        |> DateTime.to_time()
        |> Time.to_string()
        # HH:MM
        |> String.slice(0, 5)

      _ ->
        "now"
    end
  end

  defp format_time(timestamp) when is_struct(timestamp, DateTime) do
    timestamp
    |> DateTime.to_time()
    |> Time.to_string()
    # HH:MM
    |> String.slice(0, 5)
  end

  defp format_time(_), do: "now"
end
