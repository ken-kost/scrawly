defmodule ScrawlyWeb.Pages.HomePage do
  use ScrawlyWeb.Page
  use Hologram.JS

  js_import :connectDemoBoard, from: "./demo_board.mjs"
  js_import :disconnectDemoBoard, from: "./demo_board.mjs"
  js_import :clearBoard, from: "./demo_board.mjs"
  js_import :setColor, from: "./demo_board.mjs"
  js_import :setWidth, from: "./demo_board.mjs"
  js_import :setEraser, from: "./demo_board.mjs"

  js_import :copyRecoveryCode, from: "../components/recovery_code.mjs"
  js_import :downloadRecoveryCode, from: "../components/recovery_code.mjs"

  js_import :takeStaleRoomChannels, from: "./room_channels.mjs"

  js_import :openPath, from: "./room_links.mjs"

  route "/"

  alias Scrawly.Games.{LobbyChatServer, RoomServer}
  alias Scrawly.Games.RoomServer.Broadcasts
  alias ScrawlyWeb.{CommandParams, RoomCodes, RoomSettings, RoomSubscriptions}
  alias ScrawlyWeb.Components.RoomList
  alias ScrawlyWeb.Components.RoomSettingsForm
  alias ScrawlyWeb.Components.GameDemo
  alias ScrawlyWeb.Components.RecoveryCodePanel

  # The lobby chat keeps this many lines (newest first in state).
  @chat_lines 100

  # A create-room request with no reply after this long gives the form back.
  @create_room_timeout_ms 20_000

  # Same for a "have a code?" lookup.
  @join_by_code_timeout_ms 10_000

  # The room list and the lobby chat are pushed on the `:lobby` Realtime
  # channel (see "Lobby broadcasts" below); init loads the current ones and
  # subscribes.
  #
  # A short link (`/r/:code`, RoomLinkPage) that found no room redirects here
  # with a notice in the session, shown under the code field.
  def init(_params, component, server) do
    {authenticated, is_guest, username} =
      case ScrawlyWeb.Auth.current_user(server) do
        {:ok, user} -> {true, user.is_guest, user.username}
        {:error, :unauthenticated} -> {false, false, nil}
      end

    {server, code_notice} = RoomCodes.take_notice(server)

    component =
      component
      |> put_state(:rooms, RoomServer.list_lobby_rooms())
      |> put_state(:lobby_chat_messages, recent_chat_lines())
      |> put_state(:lobby_chat_input, "")
      |> put_state(:lobby_chat_notice, nil)
      |> put_state(:lobby_chat_notice_gen, 0)
      |> put_state(:mount_id, System.unique_integer([:positive]))
      |> put_state(:page_shown?, false)
      # The create-room form (RoomSettingsForm). Each opening gets a new cid
      # (`create_room_form` counts them), so it starts from the defaults.
      |> put_state(:show_create_room, false)
      |> put_state(:create_room_form, 0)
      |> put_state(:creating_room?, false)
      # Counts the requests sent, so a late timeout can't end a newer one.
      |> put_state(:create_room_attempt, 0)
      |> put_state(:create_room_errors, %{})
      |> put_state(:default_room_name, RoomSettings.default_name(username))
      # "Have a code?" (:join_by_code). Counts the lookups sent, so a late
      # timeout can't end a newer one.
      |> put_state(:room_code_input, (code_notice && code_notice.code) || "")
      |> put_state(:room_code_error, code_notice && code_notice.message)
      |> put_state(:joining_by_code?, false)
      |> put_state(:room_code_attempt, 0)
      |> put_state(:authenticated, authenticated)
      |> put_state(:is_guest, is_guest)
      |> put_state(:show_login_modal, false)
      |> put_state(:login_email, "")
      |> put_state(:login_error, "")
      # Which of the register modal's two submit buttons was pressed.
      |> put_state(:auth_intent, :register)
      |> put_reset_defaults()
      |> put_state(:recovery_code, nil)
      |> put_state(:recovery_code_saved, false)
      |> put_state(:recovery_code_copied, false)
      # Demo board tool state — sent down as props to GameDemo
      |> put_state(:demo_color, "#000000")
      |> put_state(:demo_width, 2)
      |> put_state(:demo_eraser, false)
      |> put_action(:connect_lobby)

    {component, put_subscription(server, Broadcasts.lobby_channel())}
  end

  # Server-side (init and :resync_lobby): the last chat lines, newest first.
  defp recent_chat_lines do
    LobbyChatServer.list_messages() |> Enum.reverse() |> Enum.take(@chat_lines)
  end

  # The inline script dispatches :page_shown whenever this page instance's
  # markup is inserted (Hologram runs the inline scripts a patch inserts, and
  # keys a script by its text, so @mount_id makes it run once per instance).
  def template do
    ~HOLO"""
    <div class="page">
      <script>Hologram.dispatchAction("page_shown", "page", \{mount_id: "{@mount_id}"\});</script>
      <window $key_down.n="shortcut_new" />
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
          <div class="section-label">lobby</div>
          <div class="big">{length(@rooms)} <span style="color: var(--muted); font-size: 12px;">{if(length(@rooms) == 1, do: "open room", else: "open rooms")}</span></div>
          <div class="v" style="margin-top: 6px;">live · {Enum.sum(Enum.map(@rooms, fn room -> length(room.players) end))} waiting to play</div>
        </div>
      </section>

      <div class="home-grid">
        <div class="home-rooms">
          <div class="section-header">
            <h2>open rooms</h2>
            <form class="code-join" $submit="join_by_code" $key_down.n.stop_propagation="noop">
              <input class="app-input mono" type="text" name="room_code" id="room-code-input"
                     aria-label="room code" placeholder="have a code?" maxlength="16"
                     autocomplete="off" autocapitalize="characters" spellcheck="false"
                     value={@room_code_input} $change={:update_room_code} />
              <button type="submit" class="app-btn app-btn-sm" disabled={@joining_by_code?}>
                {%if @joining_by_code?}joining…{%else}join{/if}
              </button>
            </form>
          </div>
          {%if @room_code_error}
            <div class="field-error code-join-error" role="alert">{@room_code_error}</div>
          {/if}
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
            <form class="chat-input" $submit="send_lobby_chat" $key_down.n.stop_propagation="noop">
              <input type="text" name="message" autocomplete="off" maxlength="240"
                     placeholder="message the lobby..."
                     value={@lobby_chat_input}
                     $change={:update_lobby_chat_input} />
              <button type="submit" class="app-btn app-btn-sm"
                      disabled={String.trim(@lobby_chat_input) == ""}>send</button>
            </form>
            {%if @lobby_chat_notice}
              <div class="mono" style="font-size: 11px; color: var(--muted); padding: 6px 2px 0;">{@lobby_chat_notice}</div>
            {/if}
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
          <RoomSettingsForm cid={"create-room-" <> Integer.to_string(@create_room_form)}
                            on_submit={:create_room} on_cancel={:hide_create_room}
                            busy={@creating_room?} errors={@create_room_errors}
                            name_placeholder={@default_room_name} />
        </div>
      {/if}

      {%if @show_login_modal}
        <window $key_down.escape="hide_login" />
        <div class="scrim">
          <form class="app-modal" $submit="submit_auth" $key_down.n.stop_propagation="noop">
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
                       placeholder="at least 8 characters" data-secret="1" />
              </div>
            </div>
            <div class="app-modal-foot">
              <button type="button" class="app-btn app-btn-ghost" style="margin-right: auto;" $click={:show_reset}>forgot password?</button>
              <button type="submit" class="app-btn app-btn-primary" style="order: 1;" $click={:set_auth_intent, intent: :register}>create account</button>
              <button type="submit" class="app-btn app-btn-ghost" $click={:set_auth_intent, intent: :sign_in}>sign in</button>
            </div>
          </form>
        </div>
      {/if}

      {%if @show_reset_modal}
        <window $key_down.escape="hide_reset" />
        <div class="scrim">
          <form class="app-modal" style="max-width: 420px;" $submit="submit_reset" $key_down.n.stop_propagation="noop">
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
                       spellcheck="false" placeholder="XXXX-XXXX-XXXX-XXXX-XXXX" data-secret="1" />
              </div>
              <div>
                <label class="field-label">new password</label>
                <input class="app-input" type="password" name="new_password" autocomplete="new-password"
                       placeholder="at least 8 characters" data-secret="1" />
              </div>
              <div>
                <label class="field-label">confirm new password</label>
                <input class="app-input" type="password" name="new_password_confirmation" autocomplete="new-password"
                       placeholder="repeat new password" data-secret="1" />
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
        <RecoveryCodePanel code={@recovery_code} saved={@recovery_code_saved} copied={@recovery_code_copied} />
      {/if}
    </div>
    """
  end

  defp modal_open?(state) do
    state.show_create_room or state.show_login_modal or state.show_reset_modal or
      state.recovery_code != nil
  end

  defp open_create_room(component) do
    component
    |> put_state(:show_create_room, true)
    |> put_state(:create_room_form, component.state.create_room_form + 1)
    |> put_state(:creating_room?, false)
    |> put_state(:create_room_errors, %{})
  end

  # The page's register / sign-in modal (also what guests get: :register
  # upgrades them).
  defp open_sign_in(component) do
    component
    |> put_state(:show_login_modal, true)
    |> put_state(:login_error, "")
  end

  # Passwords and recovery codes never enter the state (it is rendered into the
  # HTML and snapshotted for Back/Forward): those inputs are not synchronized,
  # the $submit actions read them from the event, and every failure, hide and
  # switch empties them in the DOM (clear_secret_fields/1).
  defp put_reset_defaults(component) do
    component
    |> put_state(:show_reset_modal, false)
    |> put_state(:reset_email, "")
    |> put_state(:reset_error, "")
  end

  # A field of a $submit event (string keys: the browser's form data).
  defp form_value(params, name) do
    event = if is_map(params), do: Map.get(params, :event)
    value = if is_map(event), do: Map.get(event, name)
    if is_binary(value), do: value, else: ""
  end

  defp clear_secret_fields(component) do
    ~JS"""
    document.querySelectorAll("input[data-secret]").forEach(function (el) { el.value = ""; });
    """

    component
  end

  # ── Keyboard: N for new ────────────────────────────────────────────
  # `<window $key_down.n>` also fires while the user types, so every form with
  # a text field on this screen stops "n" first with a `:noop` binding (a
  # binding needs a real operation: a nil one stops nothing). Apply the same
  # guard to forms added later. Ctrl/Cmd/Alt+N match the filter too; the
  # fallback clause ignores them.

  def action(
        :shortcut_new,
        %{event: %{ctrl_key: false, meta_key: false, alt_key: false}},
        component
      ) do
    state = component.state

    cond do
      modal_open?(state) -> component
      state.authenticated and not state.is_guest -> open_create_room(component)
      true -> open_sign_in(component)
    end
  end

  def action(:shortcut_new, _params, component), do: component

  def action(:noop, _params, component), do: component

  # ── Create-room modal actions ──────────────────────────────────────
  # The form (RoomSettingsForm) holds the values; this page sends them and
  # shows the outcome. The form stays open, "creating…", until the server
  # answers: :join_room_with_user on success, :create_room_failed (the values
  # stay in the form) otherwise. A reply that never comes (the command
  # crashed, the network dropped it) gives the form back after
  # @create_room_timeout_ms.

  def action(:show_create_room, _params, component), do: open_create_room(component)

  # Cancel, the close button, Escape. A request already sent still runs: if
  # it succeeds, its reply takes the user into the new room.
  def action(:hide_create_room, _params, component) do
    component
    |> put_state(:show_create_room, false)
    |> put_state(:creating_room?, false)
    |> put_state(:create_room_errors, %{})
  end

  def action(:create_room, %{values: values}, component) when is_map(values) do
    if component.state.creating_room? do
      component
    else
      attempt = component.state.create_room_attempt + 1

      component
      |> put_state(:creating_room?, true)
      |> put_state(:create_room_attempt, attempt)
      |> put_state(:create_room_errors, %{})
      |> put_command(:create_room, values)
      |> put_action(
        name: :create_room_timed_out,
        params: %{attempt: attempt},
        delay: @create_room_timeout_ms
      )
    end
  end

  def action(:create_room_failed, params, component) do
    field = Map.get(params, :field) || :form

    component
    |> put_state(:creating_room?, false)
    |> put_state(:create_room_errors, %{field => Map.get(params, :message)})
  end

  # Only for the request still waiting.
  def action(:create_room_timed_out, %{attempt: attempt}, component) do
    state = component.state

    if state.show_create_room and state.creating_room? and attempt == state.create_room_attempt do
      component
      |> put_state(:creating_room?, false)
      |> put_state(:create_room_errors, %{form: "no answer from the server, try again"})
    else
      component
    end
  end

  # ── Login / register modal actions ─────────────────────────────────

  def action(:show_login, _params, component), do: open_sign_in(component)

  def action(:hide_login, _params, component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:auth_intent, :register)
    |> clear_secret_fields()
  end

  def action(:update_login_email, %{event: %{value: val}}, component) do
    put_state(component, :login_email, val)
  end

  # Both buttons of the register modal submit its form (so the password comes
  # from the submit event); each first records which one it was. A click on a
  # submit button runs before the form's submit event, and Enter in a field
  # "clicks" the form's default button, the first submit button in the markup
  # ("create account", shown last through `order`).
  def action(:set_auth_intent, %{intent: intent}, component) do
    put_state(component, :auth_intent, if(intent == :sign_in, do: :sign_in, else: :register))
  end

  def action(:submit_auth, params, component) do
    command = if component.state.auth_intent == :sign_in, do: :sign_in, else: :register

    component
    |> put_state(:auth_intent, :register)
    |> put_command(command,
      email: component.state.login_email,
      password: form_value(params, "password")
    )
  end

  def action(:login_failed, %{message: message}, component) do
    component
    |> put_state(:login_error, message)
    |> clear_secret_fields()
  end

  # A denied command (ScrawlyWeb.Auth.deny/3) changes nothing here.
  def action(:command_denied, _params, component), do: component

  # ── Forgot password (recovery code) ────────────────────────────────

  def action(:show_reset, _params, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_login_modal, false)
    |> put_state(:show_reset_modal, true)
    |> put_state(:reset_email, component.state.login_email)
    |> clear_secret_fields()
  end

  def action(:hide_reset, _params, component) do
    component
    |> put_reset_defaults()
    |> clear_secret_fields()
  end

  def action(:update_reset_email, %{event: %{value: val}}, component) do
    put_state(component, :reset_email, val)
  end

  def action(:submit_reset, params, component) do
    component
    |> put_state(:reset_error, "")
    |> put_command(:reset_password,
      email: component.state.reset_email,
      recovery_code: form_value(params, "recovery_code"),
      password: form_value(params, "new_password"),
      password_confirmation: form_value(params, "new_password_confirmation")
    )
  end

  def action(:recovery_reset_failed, %{message: message}, component) do
    component
    |> put_state(:reset_error, message)
    |> clear_secret_fields()
  end

  # ── Recovery code panel (after register or reset) ──────────────────

  def action(:show_recovery_code, %{code: code}, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_login_modal, false)
    |> put_state(:recovery_code, code)
    |> put_state(:recovery_code_saved, false)
    |> put_state(:recovery_code_copied, false)
    |> clear_secret_fields()
  end

  def action(:copy_recovery_code, _params, component) do
    JS.call(:copyRecoveryCode, [component.state.recovery_code])
    put_state(component, :recovery_code_copied, true)
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
    |> put_state(:recovery_code_copied, false)
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

  def action(:join_room, %{room_id: room_id}, component) do
    put_action(component, :join_room_with_user, room_id: room_id)
  end

  # ── Have a code? ──────────────────────────────────────────────────
  # The input is checked here first (empty, length, alphabet:
  # RoomCodes.check/1), then the server looks the code up (:join_by_code):
  # :join_room_with_user or :open_room_as_guest when found, else
  # :room_code_failed with the line shown under the field.

  def action(:update_room_code, %{event: %{value: value}}, component) do
    component
    |> put_state(:room_code_input, value)
    |> put_state(:room_code_error, nil)
  end

  def action(:join_by_code, _params, %{state: %{joining_by_code?: true}} = component),
    do: component

  def action(:join_by_code, _params, component) do
    code = RoomCodes.normalize(component.state.room_code_input)

    case RoomCodes.check(code) do
      :ok ->
        attempt = component.state.room_code_attempt + 1

        component
        |> put_state(:joining_by_code?, true)
        |> put_state(:room_code_attempt, attempt)
        |> put_state(:room_code_error, nil)
        |> put_command(:join_by_code, code: code)
        |> put_action(
          name: :join_by_code_timed_out,
          params: %{attempt: attempt},
          delay: @join_by_code_timeout_ms
        )

      {:error, reason} ->
        put_state(component, :room_code_error, RoomCodes.message(reason))
    end
  end

  def action(:room_code_failed, params, component) do
    component
    |> put_state(:joining_by_code?, false)
    |> put_state(:room_code_error, Map.get(params, :message) || RoomCodes.message(:not_found))
  end

  # Only for the lookup still waiting.
  def action(:join_by_code_timed_out, %{attempt: attempt}, component) do
    state = component.state

    if state.joining_by_code? and attempt == state.room_code_attempt do
      component
      |> put_state(:joining_by_code?, false)
      |> put_state(:room_code_error, "no answer from the server, try again")
    else
      component
    end
  end

  # A signed-out visitor becomes a guest on the way in (`/guest`, a full page
  # load). The field is reset first: Back may restore this page as it was.
  def action(:open_room_as_guest, %{path: path}, component) do
    JS.call(:openPath, [path])

    component
    |> put_state(:joining_by_code?, false)
    |> put_state(:room_code_input, "")
  end

  # ── Demo board tools ──────────────────────────────────────────────
  # Pointer input is native (stroke_engine.mjs via demo_board.mjs); only the
  # tool state lives here and reaches JS through these calls.

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
    JS.call(:connectDemoBoard, [demo_tools(component.state)])
    component
  end

  # Dispatched by the template's inline script each time this page instance's
  # markup is put into the document: on its first render, and again when
  # Back/Forward restores the page from Hologram's snapshot. A restore runs
  # neither init nor its queued actions, brings back the lists the page was
  # left with, and the server still holds the subscriptions of the page shown
  # before (e.g. a game page's room channels) instead of `:lobby`. So the
  # second time round the page reloads both lists, subscribes again and
  # drops the rooms' subscriptions (:resync_lobby), and reconnects the demo
  # board with the tool the restored toolbar shows.
  def action(:page_shown, _params, component) do
    # Hologram 0.12.8 keeps the put_page/2 that left this page in the
    # component it saves (only next_action and next_command are cleared), so
    # after a restore the first action to return it would navigate there again
    # (Back from a game page bounced straight back to it). Drop it.
    component = %{component | next_page: nil}

    if component.state.page_shown? do
      JS.call(:connectDemoBoard, [demo_tools(component.state)])
      stale_rooms = JS.call(:takeStaleRoomChannels, [nil])

      put_command(component, :resync_lobby,
        stale_rooms: if(is_list(stale_rooms), do: stale_rooms, else: [])
      )
    else
      put_state(component, :page_shown?, true)
    end
  end

  # Also the create-room and the code lookup's reply: the form closes (and
  # the code field resets) here, so Back to this page doesn't bring it back
  # "creating…" or "joining…".
  def action(:join_room_with_user, %{room_id: room_id}, component) do
    JS.call(:disconnectDemoBoard, [])

    component
    |> put_state(:show_create_room, false)
    |> put_state(:creating_room?, false)
    |> put_state(:joining_by_code?, false)
    |> put_state(:room_code_input, "")
    |> put_page(ScrawlyWeb.Pages.GamePage, room_id: room_id)
  end

  # ── Lobby broadcasts (`:lobby`) ───────────────────────────────────
  # From the rooms (RoomServer, `Broadcasts.notify_lobby/1`) and from
  # LobbyChatServer. Realtime is at-most-once: a lost room update leaves that
  # row stale until its next change, a lost line stays missing until the next
  # page load.

  def action(:lobby_room_changed, %{room: room}, component) do
    rooms = component.state.rooms

    rooms =
      if Enum.any?(rooms, &(&1.room_id == room.room_id)),
        do: Enum.map(rooms, &if(&1.room_id == room.room_id, do: room, else: &1)),
        else: rooms ++ [room]

    put_state(component, :rooms, rooms)
  end

  def action(:lobby_room_removed, %{room_id: room_id}, component) do
    put_state(component, :rooms, Enum.reject(component.state.rooms, &(&1.room_id == room_id)))
  end

  # The sender sees its own line through this broadcast too (nothing is added
  # optimistically). A line already held (a resync overlapping a broadcast)
  # is not added twice.
  def action(:lobby_chat_received, %{id: id} = line, component) do
    messages = component.state.lobby_chat_messages

    if Enum.any?(messages, &(&1.id == id)) do
      component
    else
      line = Map.take(line, [:id, :username, :message, :is_guest, :timestamp])
      put_state(component, :lobby_chat_messages, Enum.take([line | messages], @chat_lines))
    end
  end

  def action(:lobby_chat_cleared, _params, component) do
    put_state(component, :lobby_chat_messages, [])
  end

  def action(:lobby_resynced, %{rooms: rooms, messages: messages}, component) do
    component
    |> put_state(:rooms, rooms)
    |> put_state(:lobby_chat_messages, messages)
  end

  # ── Other pages' broadcasts ───────────────────────────────────────
  # GamePage's / GameScorePage's room actions ({:room}, {:room_player}). They
  # reach this page when it was restored by Back/Forward from a game page,
  # until the restore's :resync_lobby deletes those subscriptions
  # (ScrawlyWeb.RoomSubscriptions). Explicit clauses, no catch-all: a new
  # broadcast action needs one here.

  def action(:room_delta, _params, component), do: component
  def action(:chat_appended, _params, component), do: component
  def action(:stroke_completed, _params, component), do: component
  def action(:drawing_cleared, _params, component), do: component
  def action(:drawing_undone, _params, component), do: component
  def action(:private_state, _params, component), do: component

  # ── Lobby chat ────────────────────────────────────────────────────

  def action(:update_lobby_chat_input, %{event: %{value: val}}, component) do
    put_state(component, :lobby_chat_input, val)
  end

  # The line appears when its :lobby_chat_received broadcast comes back.
  def action(:send_lobby_chat, _params, component) do
    message = String.trim(component.state.lobby_chat_input)

    if message == "" do
      component
    else
      component
      |> put_state(:lobby_chat_input, "")
      |> put_state(:lobby_chat_notice, nil)
      |> put_command(:send_lobby_chat, message: message)
    end
  end

  # The text comes back into the input unless the user has typed again. The
  # notice clears itself after 4 s (only the latest one: `gen`).
  def action(:lobby_chat_rejected, %{reason: reason} = params, component) do
    gen = component.state.lobby_chat_notice_gen + 1

    component =
      if component.state.lobby_chat_input == "",
        do: put_state(component, :lobby_chat_input, Map.get(params, :message, "")),
        else: component

    component
    |> put_state(:lobby_chat_notice, chat_notice(reason))
    |> put_state(:lobby_chat_notice_gen, gen)
    |> put_action(name: :clear_lobby_chat_notice, params: %{gen: gen}, delay: 4_000)
  end

  def action(:clear_lobby_chat_notice, %{gen: gen}, component) do
    if gen == component.state.lobby_chat_notice_gen,
      do: put_state(component, :lobby_chat_notice, nil),
      else: component
  end

  # The demo board's tool as the page's toolbar shows it.
  defp demo_tools(state) do
    %{
      color: Map.get(state, :demo_color, "#000000"),
      width: Map.get(state, :demo_width, 2),
      eraser: Map.get(state, :demo_eraser, false)
    }
  end

  defp chat_notice(:rate_limited), do: "slow down: at most 4 messages every 5 seconds."
  defp chat_notice(_reason), do: "message not sent. reload the page and try again."

  # ── Commands ─────────────────────────────────────────────────────────

  # Every clause reads its params through ScrawlyWeb.CommandParams (or Map.get
  # behind an is_map/1 guard) and the last one denies unknown names: a forged
  # command gets :command_denied, never an exception.

  # A registered user creates a room from the form's values
  # (RoomSettings.to_attrs/2) and joins it: :join_room_with_user takes them
  # there. Anything else replies :create_room_failed with a `field` (or nil)
  # and a message for the form. Guests are refused here too (the UI offers
  # them registration instead).
  def command(:create_room, params, server) when is_map(params) do
    case ScrawlyWeb.Auth.current_user(server) do
      {:ok, %{is_guest: false} = user} ->
        create_room(server, user, params)

      {:ok, _guest} ->
        put_action(server, :create_room_failed,
          field: nil,
          message: "register an account to create rooms"
        )

      {:error, :unauthenticated} ->
        put_action(server, :create_room_failed, field: nil, message: "sign in to create a room")
    end
  end

  # Upgrading a guest revokes the guest's tokens (:upgrade_guest), so its
  # sockets are told to reconnect.
  def command(:register, params, server) do
    with {:ok, %{email: email, password: password}} <-
           CommandParams.strings(params, [:email, :password]),
         {:ok, user} <- register_or_upgrade(server, email, password) do
      # The page reloads only after the user has seen the code (:close_recovery_code).
      server
      |> ScrawlyWeb.Auth.put_session_user(user, user.__metadata__.token)
      |> put_action(:show_recovery_code, code: user.__metadata__[:recovery_code])
    else
      _error ->
        put_action(server, :login_failed,
          message:
            "could not create account — use a valid email and a password of at least 8 characters"
        )
    end
  end

  def command(:reset_password, params, server) when is_map(params) do
    ScrawlyWeb.Recovery.reset_password(params, server)
  end

  # Throttled per email and per client IP inside the sign-in action
  # (ScrawlyWeb.Auth.sign_in/3, shared with AppLayout :login).
  def command(:sign_in, params, server) do
    case ScrawlyWeb.Auth.sign_in(
           server,
           CommandParams.string(params, :email),
           CommandParams.string(params, :password)
         ) do
      {:ok, _user, server} ->
        put_action(server, :reload_home)

      {:error, :throttled} ->
        put_action(server, :login_failed,
          message: "too many sign-in attempts — try again in a few minutes"
        )

      {:error, :invalid} ->
        put_action(server, :login_failed, message: "incorrect email or password")
    end
  end

  def command(:send_lobby_chat, params, server) when is_map(params) do
    ScrawlyWeb.LobbyChat.send_message(params, server)
  end

  # "Have a code?": the same lookup and per-visitor cap as the short link
  # `/r/:code` (RoomCodes.lookup/2). A signed-in visitor (a guest too) goes
  # straight to the game page; a signed-out one through `/guest`.
  def command(:join_by_code, params, server) do
    case CommandParams.string(params, :code) do
      nil ->
        CommandParams.deny_invalid(server, :join_by_code)

      code ->
        case RoomCodes.lookup(server, code) do
          {:ok, room_id} ->
            if ScrawlyWeb.Auth.user_id(server),
              do: put_action(server, :join_room_with_user, room_id: room_id),
              else:
                put_action(server, :open_room_as_guest,
                  path: RoomCodes.entry_path(server, room_id)
                )

          {:error, reason} ->
            put_action(server, :room_code_failed, message: RoomCodes.message(reason))
        end
    end
  end

  # After a Back/Forward restore (:page_shown): the current lists, the
  # :lobby subscription again, and none to the rooms in `stale_rooms`.
  def command(:resync_lobby, params, server) do
    server
    |> RoomSubscriptions.drop_stale(params, keep_lobby?: true)
    |> put_subscription(Broadcasts.lobby_channel())
    |> put_action(:lobby_resynced,
      rooms: RoomServer.list_lobby_rooms(),
      messages: recent_chat_lines()
    )
  end

  def command(name, _params, server), do: CommandParams.deny_unknown(server, name)

  # A room that was created but could not be joined or started is dissolved
  # again, so it never lingers without its host.
  defp create_room(server, user, params) do
    attrs = params |> RoomSettings.to_attrs(user.username) |> Map.put(:creator_id, user.id)

    case Scrawly.Games.create_room(attrs) do
      {:ok, room} ->
        with {:ok, _user} <- Scrawly.Accounts.join_room(user.id, room.id),
             {:ok, _room} <- Scrawly.Games.join_room(room.id, user.id),
             {:ok, _pid} <- RoomServer.ensure_started(room.id) do
          put_action(server, :join_room_with_user, room_id: room.id)
        else
          _error ->
            Scrawly.Games.dissolve_room(room.id)
            create_room_failed(server, :joining, attrs)
        end

      {:error, error} ->
        create_room_failed(server, error, attrs)
    end
  end

  defp create_room_failed(server, error, attrs) do
    {field, message} = RoomSettings.failure(error, attrs)
    put_action(server, :create_room_failed, field: field, message: message)
  end

  defp register_or_upgrade(server, email, password) do
    case ScrawlyWeb.Auth.current_user(server) do
      {:ok, %{is_guest: true} = guest} ->
        with {:ok, user} <-
               Scrawly.Accounts.upgrade_guest(guest, %{email: email, password: password}) do
          ScrawlyWeb.Auth.disconnect_sockets(guest.id)
          {:ok, user}
        end

      _ ->
        Scrawly.Accounts.register_with_password(email, password)
    end
  end
end
