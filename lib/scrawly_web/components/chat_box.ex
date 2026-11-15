defmodule ScrawlyWeb.Components.ChatBox do
  @moduledoc """
  Stateless chat component. All events bubble to the parent GamePage.

  Visitors without an account (`current_user_id` nil) can read but not type.
  "me" is marked by the message's `player_id`, which the server sets.
  """
  use Hologram.Component

  prop :messages, :list, required: true
  prop :current_message, :string, required: true
  prop :current_user_id, :string, default: nil
  prop :disabled, :boolean, default: false
  prop :is_drawer, :boolean, default: false
  prop :rate_limited, :boolean, default: false
  # A private hint for this user only (e.g. their line wasn't sent because it
  # contained the word).
  prop :notice, :string, default: nil

  def template do
    ~HOLO"""
    <div style="display: flex; flex-direction: column; flex: 1; min-height: 0;">
      <div class="panel-body" id="chat-messages" style="flex: 1; overflow: auto; padding: 4px 0;">
        {%if length(@messages) == 0}
          <div style="text-align: center; padding: 16px; color: var(--muted); font-size: 12px;">no messages yet</div>
        {/if}
        {%for msg <- Enum.reverse(@messages)}
          {%if Map.get(msg, :type) == :system}
            <div class="msg system">→ {msg.message}</div>
          {%else}
            {%if Map.get(msg, :type) == :correct_guess}
              <div class="msg correct">
                <span class="who">{Map.get(msg, :player_name, "")}</span>
                <span>{msg.message}</span>
              </div>
            {%else}
              <div class="msg">
                <span class={"who " <> if(@current_user_id != nil and Map.get(msg, :player_id) == @current_user_id, do: "me", else: "")}>{Map.get(msg, :player_name, "")}</span>
                <span>{msg.message}</span>
              </div>
            {/if}
          {/if}
        {/for}
      </div>
      {%if @rate_limited}
        <div style="padding: 4px 14px; font-size: 11px; color: var(--danger);">slow down</div>
      {/if}
      {%if @notice}
        <div style="padding: 4px 14px; font-size: 11px; color: var(--muted);">{@notice}</div>
      {/if}
      <form class="chat-input" $submit="send_message">
        <input type="text" name="message" maxlength="240"
               placeholder={if(@current_user_id == nil, do: "sign in to chat", else: if(@is_drawer, do: "you are drawing — chat disabled", else: "type a guess..."))}
               value={@current_message}
               disabled={@disabled || @current_user_id == nil}
               $change={:update_message}
               $key_down.escape.prevent_default="clear_message" />
        <button type="submit" class="app-btn app-btn-sm" disabled={@disabled || @current_user_id == nil || String.trim(@current_message) == ""}>send</button>
      </form>
    </div>
    """
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
