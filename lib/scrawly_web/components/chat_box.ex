defmodule ScrawlyWeb.Components.ChatBox do
  @moduledoc """
  Stateless chat component. All events bubble to the parent GamePage.
  """
  use Hologram.Component

  prop :messages, :list, default: []
  prop :current_message, :string, default: ""
  prop :current_user_id, :string, default: nil
  prop :current_user_name, :string, default: nil
  prop :disabled, :boolean, default: false
  prop :is_drawer, :boolean, default: false
  prop :rate_limited, :boolean, default: false

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
              {%if Map.get(msg, :type) == :close_guess}
                <div class="msg close">
                  <span class="who">{Map.get(msg, :player_name, "")}</span>
                  <span>{msg.message}</span>
                  <span class="mono" style="margin-left: auto; font-size: 11px; color: var(--muted);">close</span>
                </div>
              {%else}
                {%if Map.get(msg, :type) == :round_complete}
                  <div class="msg system">→ {msg.message}</div>
                {%else}
                  <div class="msg">
                    <span class={"who " <> if(Map.get(msg, :player_name) == @current_user_id, do: "me", else: "")}>{Map.get(msg, :player_name, "")}</span>
                    <span>{msg.message}</span>
                  </div>
                {/if}
              {/if}
            {/if}
          {/if}
        {/for}
      </div>
      {%if @rate_limited}
        <div style="padding: 4px 14px; font-size: 11px; color: var(--danger);">slow down</div>
      {/if}
      <form class="chat-input" $submit="send_message">
        <input type="text" name="message"
               placeholder={if(@is_drawer, do: "you are drawing — chat disabled", else: "type a guess...")}
               value={@current_message}
               disabled={@disabled}
               $input={:update_message} />
        <button type="submit" class="app-btn app-btn-sm" disabled={@disabled || String.trim(@current_message) == ""}>send</button>
      </form>
    </div>
    """
  end
end
