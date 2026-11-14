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

  js_import :copyRecoveryCode, from: "../components/recovery_code.mjs"
  js_import :downloadRecoveryCode, from: "../components/recovery_code.mjs"

  route "/"

  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.RoomList
  alias ScrawlyWeb.Components.GameDemo
  alias ScrawlyWeb.Components.RecoveryCodePanel

  def init(_params, component, server) do
    {authenticated, is_guest} =
      case get_session(server, "user_id") do
        nil ->
          {false, false}

        user_id ->
          case Ash.get(Scrawly.Accounts.User, user_id) do
            {:ok, user} -> {true, user.is_guest}
            _ -> {false, false}
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
    |> put_state(:is_guest, is_guest)
    |> put_state(:show_login_modal, false)
    |> put_state(:login_email, "")
    |> put_state(:login_password, "")
    |> put_state(:login_error, "")
    |> put_reset_defaults()
    |> put_state(:recovery_code, nil)
    |> put_state(:recovery_code_saved, false)
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
            {%if @authenticated && !@is_guest}
              <button class="app-btn app-btn-primary app-btn-lg" $click={:show_create_room}>
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="16" height="16"><path d="M12 5v14M5 12h14" stroke-linecap="round"/></svg>
                create a room
              </button>
            {%else}
              {%if @is_guest}
                <button class="app-btn app-btn-primary app-btn-lg" $click={:show_login}>register to create rooms</button>
              {%else}
                <button class="app-btn app-btn-primary app-btn-lg" $click={:show_login}>
                  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" width="16" height="16"><path d="M12 5v14M5 12h14" stroke-linecap="round"/></svg>
                  create a room
                </button>
                <a class="app-btn app-btn-lg" href="/guest">play as guest</a>
              {/if}
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
          <RoomList rooms={@rooms} />

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
                <input class="app-input" placeholder="e.g. late night doodles" name="room_name" maxlength="40" value={@new_room_name} $change={:update_room_name} />
              </div>
              <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px;">
                <div>
                  <label class="field-label">max players</label>
                  <input class="app-input mono" type="number" min="2" max="12" name="max_players" value={@new_max_players} $change={:update_max_players} />
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
                  <input class="app-input" placeholder="ocean animals, things in a kitchen..." maxlength="200" value={@new_prompt} $change={:update_prompt} />
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

      {%if @show_login_modal}
        <div class="scrim">
          <form class="app-modal" $submit="submit_register">
            <div class="app-modal-head">
              <div>
                <h3>create an account</h3>
                <div class="sub">register to create and host rooms.</div>
              </div>
              <button type="button" class="icon-btn" $click={:hide_login}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="18" height="18"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round"/></svg>
              </button>
            </div>
            <div class="app-modal-body">
              {%if @login_error != ""}
                <div style="color: var(--danger); font-size: 13px; margin-bottom: 4px;">{@login_error}</div>
              {/if}
              <div>
                <label class="field-label">email</label>
                <input class="app-input" type="email" name="email" autocomplete="email"
                       placeholder="you@example.com"
                       value={@login_email} $change={:update_login_email} />
              </div>
              <div>
                <label class="field-label">password</label>
                <input class="app-input" type="password" name="password" autocomplete="current-password"
                       placeholder="at least 8 characters"
                       value={@login_password} $change={:update_login_password} />
              </div>
            </div>
            <div class="app-modal-foot">
              <button type="button" class="app-btn app-btn-ghost" style="margin-right: auto;" $click={:show_reset}>forgot password?</button>
              <button type="button" class="app-btn app-btn-ghost" $click={:submit_sign_in}>sign in</button>
              <button type="submit" class="app-btn app-btn-primary">create account</button>
            </div>
          </form>
        </div>
      {/if}

      {%if @show_reset_modal}
        <div class="scrim">
          <form class="app-modal" style="max-width: 420px;" $submit="submit_reset">
            <div class="app-modal-head">
              <div>
                <h3>reset your password</h3>
                <div class="sub">use the recovery code you saved when you registered.</div>
              </div>
              <button type="button" class="icon-btn" $click={:hide_reset}>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="18" height="18"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round"/></svg>
              </button>
            </div>
            <div class="app-modal-body">
              {%if @reset_error != ""}
                <div style="color: var(--danger); font-size: 13px; margin-bottom: 4px;">{@reset_error}</div>
              {/if}
              <div>
                <label class="field-label">email</label>
                <input class="app-input" type="email" name="email" autocomplete="email"
                       placeholder="you@example.com"
                       value={@reset_email} $change={:update_reset_email} />
              </div>
              <div>
                <label class="field-label">recovery code</label>
                <input class="app-input mono" type="text" name="recovery_code" autocomplete="off"
                       spellcheck="false" placeholder="XXXX-XXXX-XXXX-XXXX-XXXX"
                       value={@reset_code} $change={:update_reset_code} />
              </div>
              <div>
                <label class="field-label">new password</label>
                <input class="app-input" type="password" name="new_password" autocomplete="new-password"
                       placeholder="at least 8 characters"
                       value={@reset_password} $change={:update_reset_password} />
              </div>
              <div>
                <label class="field-label">confirm new password</label>
                <input class="app-input" type="password" name="new_password_confirmation" autocomplete="new-password"
                       placeholder="repeat new password"
                       value={@reset_password_confirmation} $change={:update_reset_password_confirmation} />
              </div>
            </div>
            <div class="app-modal-foot">
              <button type="button" class="app-btn app-btn-ghost" $click={:hide_reset}>cancel</button>
              <button type="submit" class="app-btn app-btn-primary">set new password</button>
            </div>
          </form>
        </div>
      {/if}

      {%if @recovery_code}
        <RecoveryCodePanel code={@recovery_code} saved={@recovery_code_saved} />
      {/if}
    </div>
    """
  end

  defp put_reset_defaults(component) do
    component
    |> put_state(:show_reset_modal, false)
    |> put_state(:reset_email, "")
    |> put_state(:reset_code, "")
    |> put_state(:reset_password, "")
    |> put_state(:reset_password_confirmation, "")
    |> put_state(:reset_error, "")
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

  # ── Login / register modal actions ─────────────────────────────────

  def action(:show_login, _params, component) do
    component
    |> put_state(:show_login_modal, true)
    |> put_state(:login_error, "")
  end

  def action(:hide_login, _params, component) do
    put_state(component, :show_login_modal, false)
  end

  def action(:update_login_email, %{event: %{value: val}}, component) do
    put_state(component, :login_email, val)
  end

  def action(:update_login_password, %{event: %{value: val}}, component) do
    put_state(component, :login_password, val)
  end

  def action(:submit_register, _params, component) do
    put_command(component, :register,
      email: component.state.login_email,
      password: component.state.login_password
    )
  end

  def action(:submit_sign_in, _params, component) do
    put_command(component, :sign_in,
      email: component.state.login_email,
      password: component.state.login_password
    )
  end

  def action(:login_failed, %{message: message}, component) do
    put_state(component, :login_error, message)
  end

  # ── Forgot password (recovery code) ────────────────────────────────

  def action(:show_reset, _params, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_login_modal, false)
    |> put_state(:show_reset_modal, true)
    |> put_state(:reset_email, component.state.login_email)
  end

  def action(:hide_reset, _params, component) do
    put_reset_defaults(component)
  end

  def action(:update_reset_email, %{event: %{value: val}}, component) do
    put_state(component, :reset_email, val)
  end

  def action(:update_reset_code, %{event: %{value: val}}, component) do
    put_state(component, :reset_code, val)
  end

  def action(:update_reset_password, %{event: %{value: val}}, component) do
    put_state(component, :reset_password, val)
  end

  def action(:update_reset_password_confirmation, %{event: %{value: val}}, component) do
    put_state(component, :reset_password_confirmation, val)
  end

  def action(:submit_reset, _params, component) do
    component
    |> put_state(:reset_error, "")
    |> put_command(:reset_password,
      email: component.state.reset_email,
      recovery_code: component.state.reset_code,
      password: component.state.reset_password,
      password_confirmation: component.state.reset_password_confirmation
    )
  end

  def action(:recovery_reset_failed, %{message: message}, component) do
    put_state(component, :reset_error, message)
  end

  # ── Recovery code panel (after register or reset) ──────────────────

  def action(:show_recovery_code, %{code: code}, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_login_modal, false)
    |> put_state(:login_password, "")
    |> put_state(:recovery_code, code)
    |> put_state(:recovery_code_saved, false)
  end

  def action(:copy_recovery_code, _params, component) do
    JS.call(:copyRecoveryCode, [component.state.recovery_code])
    component
  end

  def action(:download_recovery_code, _params, component) do
    JS.call(:downloadRecoveryCode, [component.state.recovery_code])
    component
  end

  def action(:set_recovery_code_saved, %{event: %{value: saved}}, component) do
    put_state(component, :recovery_code_saved, saved == true)
  end

  def action(:close_recovery_code, _params, component) do
    component
    |> put_state(:recovery_code, nil)
    |> put_state(:recovery_code_saved, false)
    |> put_action(:reload_home)
  end

  # A full page load, so the header, sockets and state come from the new
  # session. A reload rather than location.assign('/'): on a same-URL
  # navigation Hologram restores the page snapshot it saved for this history
  # entry, which still holds the previous identity's state.
  def action(:reload_home, _params, component) do
    JS.exec(~JS"""
      window.location.reload();
    """)

    component
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

  @ai_tones %{"fun" => :fun, "creative" => :creative, "weird" => :weird}

  # Total over any params map: forged values (`word_count: "abc"`, an unknown
  # tone) become invalid inputs that the Room's constraints reject, never an
  # exception. Missing (nil) values are left out, so the Room's defaults apply.
  defp room_attrs(params) do
    word_source = if Map.get(params, :word_source) == "ai", do: :ai, else: :local

    %{
      name: Map.get(params, :name),
      max_players: parse_int(Map.get(params, :max_players)),
      word_count: parse_int(Map.get(params, :word_count)),
      word_source: word_source,
      prompt: if(word_source == :ai, do: Map.get(params, :prompt)),
      round_duration: parse_int(Map.get(params, :round_duration)),
      round_multiplier: parse_int(Map.get(params, :round_multiplier)),
      ai_tone: if(word_source == :ai, do: ai_tone(Map.get(params, :ai_tone)))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # An unparsable value goes through as is, so the attribute's cast rejects it.
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp parse_int(value), do: value

  defp ai_tone(tone), do: Map.get(@ai_tones, tone, tone)

  # Non-guest authenticated user creates room — they become creator and auto-join.
  # Guests are rejected here (the UI also hides the button for them).
  def command(:create_room, params, server) do
    user_id = get_session(server, :user_id)

    with {:ok, %{is_guest: false}} <- Ash.get(Scrawly.Accounts.User, user_id),
         attrs = Map.put(room_attrs(params), :creator_id, user_id),
         {:ok, room} <- Scrawly.Games.create_room(attrs),
         {:ok, _user} <- Scrawly.Accounts.join_room(user_id, room.id),
         {:ok, _room} <- Scrawly.Games.join_room(room.id, user_id),
         {:ok, _pid} <- Scrawly.Games.RoomServer.ensure_started(room.id) do
      put_action(server, :join_room_with_user, room_id: room.id)
    else
      _ -> server
    end
  end

  def command(:register, %{email: email, password: password}, server) do
    user_id = get_session(server, :user_id)

    result =
      case user_id && Ash.get(Scrawly.Accounts.User, user_id) do
        {:ok, %{is_guest: true} = guest} ->
          Scrawly.Accounts.upgrade_guest(guest, %{email: email, password: password})

        _ ->
          Scrawly.Accounts.register_with_password(email, password)
      end

    case result do
      {:ok, user} ->
        # The page reloads only after the user has seen the code (:close_recovery_code).
        server
        |> put_session(:user_id, user.id)
        |> put_session(:user_token, user.__metadata__[:token])
        |> put_action(:show_recovery_code, code: user.__metadata__[:recovery_code])

      {:error, _} ->
        put_action(server, :login_failed,
          message:
            "could not create account — use a valid email and a password of at least 8 characters"
        )
    end
  end

  def command(:reset_password, params, server) do
    ScrawlyWeb.Recovery.reset_password(params, server)
  end

  def command(:sign_in, %{email: email, password: password}, server) do
    case Scrawly.Accounts.sign_in_with_password(email, password) do
      {:ok, user} ->
        server
        |> put_session(:user_id, user.id)
        |> put_session(:user_token, user.__metadata__[:token])
        |> put_action(:reload_home)

      {:error, _} ->
        put_action(server, :login_failed, message: "incorrect email or password")
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
