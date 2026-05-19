defmodule ScrawlyWeb.Pages.HomePage do
  use Hologram.Page
  use Hologram.JS

  js_import :connectLobbyChannel, from: "./lobby_channel.mjs"
  js_import :disconnectLobbyChannel, from: "./lobby_channel.mjs"
  js_import :sendLobbyChat, from: "./lobby_channel.mjs"
  js_import :installHomeKeybinds, from: "./home_keybinds.mjs"
  js_import :uninstallHomeKeybinds, from: "./home_keybinds.mjs"

  js_import :connectDemoBoard, from: "./demo_board.mjs"
  js_import :disconnectDemoBoard, from: "./demo_board.mjs"
  js_import :startStroke, from: "./demo_board.mjs"
  js_import :continueStroke, from: "./demo_board.mjs"
  js_import :endStroke, from: "./demo_board.mjs"
  js_import :clearBoard, from: "./demo_board.mjs"
  js_import :setColor, from: "./demo_board.mjs"
  js_import :setWidth, from: "./demo_board.mjs"
  js_import :setEraser, from: "./demo_board.mjs"

  route "/"

  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.RoomList
  alias ScrawlyWeb.Components.GameDemo

  def init(_params, component, server) do
    authenticated =
      case get_session(server, "user_id") do
        nil ->
          false

        user_id ->
          case Ash.get(Scrawly.Accounts.User, user_id) do
            {:ok, _user} -> true
            _ -> false
          end
      end

    lobby_rooms =
      Scrawly.Games.RoomServer.list_active_rooms()
      |> Enum.filter(&(&1.status == :lobby))

    token = get_session(server, :user_token) || ""

    lobby_chat_messages =
      Scrawly.Games.LobbyChatServer.list_messages()
      |> Enum.map(fn m ->
        %{
          username: m["username"],
          message: m["message"],
          is_guest: m["is_guest"],
          timestamp: m["timestamp"]
        }
      end)
      |> Enum.reverse()

    component
    |> put_state(:rooms, lobby_rooms)
    |> put_state(:lobby_chat_messages, lobby_chat_messages)
    |> put_state(:lobby_chat_input, "")
    |> put_state(:show_create_room, false)
    |> put_state(:new_room_name, "")
    |> put_state(:new_max_players, "8")
    |> put_state(:new_word_count, "1")
    |> put_state(:new_word_source, "local")
    |> put_state(:new_prompt, "")
    |> put_state(:new_round_duration, "60")
    |> put_state(:new_round_multiplier, "1")
    |> put_state(:new_ai_tone, "fun")
    |> put_state(:authenticated, authenticated)
    |> put_state(:socket_token, token)
    # Demo board tool state — sent down as props to GameDemo
    |> put_state(:demo_color, "#000000")
    |> put_state(:demo_width, 2)
    |> put_state(:demo_eraser, false)
    |> put_action(:connect_lobby)
  end

  def template do
    ~HOLO"""
    <div class="page">
      <section class="hero">
        <div>
          <h1>draw.<span class="slash">/</span>guess.<br/>quietly.</h1>
          <p class="sub" style="margin-top: 16px;">
            a pen, a word, sixty seconds. scrawly is a small online game
            where one person draws and everyone else races to name it.
          </p>
          <div class="row" style="gap: 8px; margin-top: 24px;">
            {%if @authenticated}
              <button class="app-btn app-btn-primary app-btn-lg" $click={:show_create_room}>
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="16" height="16"><path d="M12 5v14M5 12h14" stroke-linecap="round"/></svg>
                create a room
              </button>
            {%else}
              <button class="app-btn app-btn-primary app-btn-lg" $click={:show_login}>
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="16" height="16"><path d="M12 5v14M5 12h14" stroke-linecap="round"/></svg>
                create a room
              </button>
            {/if}
            <span class="mono" style="font-size: 12px; color: var(--muted); margin-left: 8px;">
              press <span class="kbd">N</span> for new
            </span>
          </div>
        </div>
        <div class="meta">
          <div class="section-label">today</div>
          <div class="big">{length(@rooms)} <span style="color: var(--muted); font-size: 12px;">rooms</span></div>
          <div class="v" style="margin-top: 6px;">live · {length(@rooms)} open</div>
        </div>
      </section>

      <div class="home-grid">
        <div class="home-rooms">
          <div class="section-header">
            <h2>open rooms</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">live</span>
          </div>
          <RoomList rooms={@rooms} loading={false} />

          <div class="lobby-chat">
            <div class="section-header">
              <h2>lobby chat</h2>
              <span class="mono" style="font-size: 11px; color: var(--muted);">everyone</span>
            </div>
            <div class="lobby-chat-body" id="lobby-chat-messages">
              {%if length(@lobby_chat_messages) == 0}
                <div style="text-align: center; padding: 12px; color: var(--muted); font-size: 12px;">
                  no messages yet — say hi.
                </div>
              {%else}
                {%for msg <- Enum.reverse(@lobby_chat_messages)}
                  <div class="msg">
                    <span class={"who" <> if(msg.is_guest, do: " guest", else: "")}>{msg.username}</span>
                    <span>{msg.message}</span>
                  </div>
                {/for}
              {/if}
            </div>
            <form class="chat-input" $submit="send_lobby_chat">
              <input type="text" name="message" autocomplete="off" maxlength="240"
                     placeholder="message the lobby..."
                     value={@lobby_chat_input}
                     $input={:update_lobby_chat_input} />
              <button type="submit" class="app-btn app-btn-sm"
                      disabled={String.trim(@lobby_chat_input) == ""}>send</button>
            </form>
          </div>
        </div>
        <div class="home-demo">
          <div class="section-header">
            <h2>demo</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">one shared board · everyone draws</span>
          </div>
          <GameDemo color={@demo_color} width={@demo_width} eraser={@demo_eraser} />
          <div style="margin-top: 16px; padding: 16px; border: 1px solid var(--hairline); border-radius: 8px;">
            <div class="section-label">how it works</div>
            <ol style="margin: 12px 0 0; padding-left: 18px; color: var(--muted); font-size: 13px; line-height: 1.65;">
              <li>one player draws the word, no typing allowed.</li>
              <li>everyone else guesses in chat. fastest correct gets the most points.</li>
              <li>after 60s, roles rotate. play three rounds, see who comes out on top.</li>
            </ol>
          </div>
        </div>
      </div>

      {%if @show_create_room}
        <div class="scrim">
          <form class="app-modal" $submit="create_room">
            <div class="app-modal-head">
              <div>
                <h3>new room</h3>
                <div class="sub">configure how the round runs.</div>
              </div>
              <button type="button" class="icon-btn" $click={:hide_create_room}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="18" height="18"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round"/></svg>
              </button>
            </div>
            <div class="app-modal-body">
              <div>
                <label class="field-label">name</label>
                <input class="app-input" placeholder="e.g. late night doodles" name="room_name" value={@new_room_name} $input={:update_room_name} />
              </div>
              <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px;">
                <div>
                  <label class="field-label">max players</label>
                  <input class="app-input mono" type="number" min="2" max="12" name="max_players" value={@new_max_players} $input={:update_max_players} />
                </div>
                <div>
                  <label class="field-label">words / round</label>
                  <div class="seg">
                    {%for wc <- ["1", "2", "3"]}
                      <button type="button" class={if(@new_word_count == wc, do: "active", else: "")} $click={:set_word_count, value: wc}>{wc}</button>
                    {/for}
                  </div>
                </div>
              </div>
              <div>
                <label class="field-label">word source</label>
                <div class="seg">
                  <button type="button" class={if(@new_word_source == "local", do: "active", else: "")} $click={:set_word_source, value: "local"}>local list</button>
                  <button type="button" class={if(@new_word_source == "ai", do: "active", else: "")} $click={:set_word_source, value: "ai"}>ai generated</button>
                </div>
              </div>
              {%if @new_word_source == "ai"}
                <div>
                  <label class="field-label">theme prompt</label>
                  <input class="app-input" placeholder="ocean animals, things in a kitchen..." value={@new_prompt} $input={:update_prompt} />
                </div>
                <div>
                  <label class="field-label">tone</label>
                  <div class="seg">
                    {%for t <- ["fun", "creative", "weird"]}
                      <button type="button" class={if(@new_ai_tone == t, do: "active", else: "")} $click={:set_ai_tone, value: t}>{t}</button>
                    {/for}
                  </div>
                </div>
              {/if}
              <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px;">
                <div>
                  <label class="field-label">rounds / player</label>
                  <div class="seg">
                    {%for r <- ["1", "2", "3", "5"]}
                      <button type="button" class={if(@new_round_multiplier == r, do: "active", else: "")} $click={:set_round_multiplier, value: r}>{r}×</button>
                    {/for}
                  </div>
                </div>
                <div>
                  <label class="field-label">duration</label>
                  <div class="seg">
                    {%for {dur, lbl} <- [{"60", "60s"}, {"120", "2m"}, {"300", "5m"}]}
                      <button type="button" class={if(@new_round_duration == dur, do: "active", else: "")} $click={:set_round_duration, value: dur}>{lbl}</button>
                    {/for}
                  </div>
                </div>
              </div>
            </div>
            <div class="app-modal-foot">
              <button type="button" class="app-btn app-btn-ghost" $click={:hide_create_room}>cancel</button>
              <button type="submit" class="app-btn app-btn-primary">create room</button>
            </div>
          </form>
        </div>
      {/if}
    </div>
    """
  end

  # ── Create-room modal actions ──────────────────────────────────────

  def action(:show_create_room, _params, component) do
    put_state(component, :show_create_room, true)
  end

  def action(:hide_create_room, _params, component) do
    component
    |> put_state(:show_create_room, false)
    |> put_state(:new_max_players, "8")
    |> put_state(:new_word_count, "1")
    |> put_state(:new_word_source, "local")
    |> put_state(:new_prompt, "")
    |> put_state(:new_round_duration, "60")
    |> put_state(:new_round_multiplier, "1")
    |> put_state(:new_ai_tone, "fun")
  end

  def action(:update_room_name, %{event: %{value: name}}, component) do
    put_state(component, :new_room_name, name)
  end

  def action(:update_max_players, %{event: %{value: val}}, component) do
    put_state(component, :new_max_players, val)
  end

  def action(:set_word_count, %{value: val}, component) do
    put_state(component, :new_word_count, val)
  end

  def action(:set_word_source, %{value: val}, component) do
    component
    |> put_state(:new_word_source, val)
    |> then(fn c -> if val == "local", do: put_state(c, :new_prompt, ""), else: c end)
  end

  def action(:update_prompt, %{event: %{value: val}}, component) do
    put_state(component, :new_prompt, val)
  end

  def action(:set_round_duration, %{value: val}, component) do
    put_state(component, :new_round_duration, val)
  end

  def action(:set_round_multiplier, %{value: val}, component) do
    put_state(component, :new_round_multiplier, val)
  end

  def action(:set_ai_tone, %{value: val}, component) do
    put_state(component, :new_ai_tone, val)
  end

  def action(:create_room, _params, component) do
    params = %{
      name: component.state.new_room_name,
      max_players: component.state.new_max_players,
      word_count: component.state.new_word_count,
      word_source: component.state.new_word_source,
      prompt: component.state.new_prompt,
      round_duration: component.state.new_round_duration,
      round_multiplier: component.state.new_round_multiplier,
      ai_tone: component.state.new_ai_tone
    }

    component
    |> put_state(:show_create_room, false)
    |> put_command(:create_room, params)
  end

  def action(:home, _params, component) do
    put_page(component, ScrawlyWeb.Pages.HomePage)
  end

  def action(:join_room, %{room_id: room_id}, component) do
    put_action(component, :join_room_with_user, room_id: room_id)
  end

  # ── Demo board pointer + tools (event-driven, no ticks) ────────────

  def action(:demo_pointer_down, params, component) do
    x = params.event.offset_x
    y = params.event.offset_y
    JS.call(:startStroke, [x, y])
    component
  end

  def action(:demo_pointer_move, params, component) do
    x = params.event.offset_x
    y = params.event.offset_y
    JS.call(:continueStroke, [x, y])
    component
  end

  def action(:demo_pointer_up, _params, component) do
    JS.call(:endStroke, [])
    component
  end

  def action(:demo_clear, _params, component) do
    JS.call(:clearBoard, [])
    component
  end

  def action(:demo_set_color, %{value: color}, component) do
    JS.call(:setColor, [color])

    component
    |> put_state(:demo_color, color)
    |> put_state(:demo_eraser, false)
  end

  def action(:demo_set_width, %{value: width}, component) do
    JS.call(:setWidth, [width])

    component
    |> put_state(:demo_width, width)
    |> put_state(:demo_eraser, false)
  end

  def action(:demo_toggle_eraser, _params, component) do
    new_eraser = not component.state.demo_eraser

    if new_eraser,
      do: JS.call(:setEraser, []),
      else: JS.call(:setColor, [component.state.demo_color])

    put_state(component, :demo_eraser, new_eraser)
  end

  # ── Lobby & Room Actions ──────────────────────────────────────────

  def action(:connect_lobby, _params, component) do
    token = Map.get(component.state, :socket_token, "")
    JS.call(:connectLobbyChannel, [token])
    JS.call(:installHomeKeybinds, [component.state.authenticated])
    JS.call(:connectDemoBoard, [])
    component
  end

  def action(:join_room_with_user, %{room_id: room_id}, component) do
    JS.call(:disconnectLobbyChannel, [])
    JS.call(:uninstallHomeKeybinds, [])
    JS.call(:disconnectDemoBoard, [])
    put_page(component, ScrawlyWeb.Pages.GamePage, room_id: room_id)
  end

  def action(:watch_room, %{room_id: room_id}, component) do
    JS.call(:disconnectLobbyChannel, [])
    JS.call(:uninstallHomeKeybinds, [])
    JS.call(:disconnectDemoBoard, [])
    put_command(component, :enter_watch_mode, room_id: room_id)
  end

  def action(:refresh_rooms, _params, component) do
    put_command(component, :refresh_rooms)
  end

  def action(:rooms_refreshed, %{rooms: rooms}, component) do
    put_state(component, :rooms, rooms)
  end

  # ── Lobby chat ────────────────────────────────────────────────────

  def action(:update_lobby_chat_input, %{event: %{value: val}}, component) do
    put_state(component, :lobby_chat_input, val)
  end

  def action(:send_lobby_chat, _params, component) do
    message = component.state.lobby_chat_input |> String.trim()

    if message == "" do
      component
    else
      JS.call(:sendLobbyChat, [message])
      put_state(component, :lobby_chat_input, "")
    end
  end

  def action(:lobby_chat_received, params, component) do
    msg = %{
      username: params.username,
      message: params.message,
      is_guest: params.is_guest,
      timestamp: params.timestamp
    }

    messages = [msg | component.state.lobby_chat_messages] |> Enum.take(100)
    put_state(component, :lobby_chat_messages, messages)
  end

  def action(:lobby_chat_history_loaded, %{messages: messages}, component) do
    history =
      messages
      |> Enum.map(fn m ->
        %{
          username: Map.get(m, :username) || Map.get(m, "username"),
          message: Map.get(m, :message) || Map.get(m, "message"),
          is_guest: Map.get(m, :is_guest) || Map.get(m, "is_guest"),
          timestamp: Map.get(m, :timestamp) || Map.get(m, "timestamp")
        }
      end)
      |> Enum.reverse()

    put_state(component, :lobby_chat_messages, history)
  end

  def action(:lobby_chat_cleared, _params, component) do
    put_state(component, :lobby_chat_messages, [])
  end

  # ── Commands ─────────────────────────────────────────────────────────

  defp room_attrs(params) do
    word_source = if params.word_source == "ai", do: :ai, else: :local
    word_count = String.to_integer(params.word_count || "1")
    round_duration = String.to_integer(params.round_duration || "60")
    round_multiplier = String.to_integer(params.round_multiplier || "1")
    ai_tone = String.to_existing_atom(params.ai_tone || "fun")

    %{
      name: params.name,
      max_players: params.max_players,
      word_count: word_count,
      word_source: word_source,
      prompt: if(word_source == :ai, do: params.prompt, else: nil),
      round_duration: round_duration,
      round_multiplier: round_multiplier,
      ai_tone: if(word_source == :ai, do: ai_tone, else: :fun)
    }
  end

  # Authenticated user creates room — they become creator and auto-join
  def command(:create_room, params, server) do
    user_id = get_session(server, :user_id)
    attrs = Map.put(room_attrs(params), :creator_id, user_id)

    with {:ok, room} <- Scrawly.Games.create_room(attrs),
         {:ok, _user} <- Scrawly.Accounts.join_room(user_id, room.id),
         {:ok, _room} <- Scrawly.Games.join_room(room.id, user_id),
         {:ok, _pid} <- Scrawly.Games.RoomServer.ensure_started(room.id) do
      put_action(server, :join_room_with_user, room_id: room.id)
    else
      _ -> server
    end
  end

  # Set watch_mode flag in session, then navigate to game page
  def command(:enter_watch_mode, %{room_id: room_id}, server) do
    server
    |> put_session(:watch_mode, "yes")
    |> put_action(:join_room_with_user, room_id: room_id)
  end

  # Refresh room list — only show rooms with active RoomServers
  def command(:refresh_rooms, _params, server) do
    rooms =
      Scrawly.Games.RoomServer.list_active_rooms()
      |> Enum.filter(&(&1.status == :lobby))

    put_action(server, :rooms_refreshed, rooms: rooms)
  end
end
