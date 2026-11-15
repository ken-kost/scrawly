defmodule ScrawlyWeb.Layouts.AppLayout do
  use Hologram.Component
  use Hologram.JS

  js_import :copyRecoveryCode, from: "../components/recovery_code.mjs"
  js_import :downloadRecoveryCode, from: "../components/recovery_code.mjs"

  alias Hologram.UI.Runtime
  alias Hologram.UI.Link
  alias ScrawlyWeb.CommandParams
  alias ScrawlyWeb.Components.{Avatar, AvatarDefs, RecoveryCodePanel}
  alias ScrawlyWeb.OnlineTracker

  # Runs before the layout's own commands only (component middleware never
  # runs on render: the page's does). They get the same session check as page
  # commands: a revoked session is signed out here too. :id_only, so
  # :presence_ping (every 20 s per tab) costs one tokens lookup and no users
  # query; :save_theme / :save_accent load the user lazily.
  middleware ScrawlyWeb.Middleware.LoadCurrentUser, load: :id_only

  @accents [:purple, :yellow, :orange]

  # The presence heartbeat (see "Online presence" below).
  @ping_ms 20_000
  @ping_dead_ms 30_000

  # The page's ScrawlyWeb.Middleware.LoadCurrentUser (use ScrawlyWeb.Page) has
  # checked the session and stashed the user; the struct a page's init returns
  # is threaded in here, so the layout never queries the user itself when the
  # stash holds it. Only copied fields reach the state (it is sent to the
  # browser; the record carries hashed_password).
  def init(_props, component, server) do
    ensure_current_user_loaded!(server)

    session_dark = get_session(server, :dark_mode) == true
    session_accent = get_session(server, :accent_color) |> accent_or_default()

    identity =
      case ScrawlyWeb.Auth.current_user(server) do
        {:ok, user} ->
          %{
            authenticated: true,
            username: user.username,
            user_id: user.id,
            avatar_id: user.avatar_id || AvatarDefs.default_id(),
            avatar_color: user.avatar_color || AvatarDefs.default_color(),
            dark_mode: user.dark_mode || session_dark,
            accent: if(user.accent_color in @accents, do: user.accent_color, else: session_accent)
          }

        {:error, :unauthenticated} ->
          %{
            authenticated: false,
            username: nil,
            user_id: nil,
            avatar_id: AvatarDefs.default_id(),
            avatar_color: AvatarDefs.default_color(),
            dark_mode: session_dark,
            accent: session_accent
          }
      end

    OnlineTracker.touch(ScrawlyWeb.Auth.actor_key(server))
    ping_gen = System.unique_integer([:positive])

    component =
      component
      |> put_state(identity)
      |> put_auth_defaults()
      |> put_state(:online_count, OnlineTracker.count())
      |> put_state(:ping_gen, ping_gen)
      |> put_state(:last_ping_at, nil)
      # Keys the template's inline script (:layout_shown) to this instance.
      |> put_state(:mount_id, System.unique_integer([:positive]))
      |> put_state(:layout_shown?, false)
      |> put_action(name: :presence_ping, params: %{gen: ping_gen}, delay: @ping_ms)

    {component, put_subscription(server, OnlineTracker.channel())}
  end

  defp ensure_current_user_loaded!(server) do
    if get_stash(server, :current_user_id, :not_loaded) == :not_loaded do
      raise ArgumentError,
            "#{inspect(__MODULE__)} needs ScrawlyWeb.Middleware.LoadCurrentUser to run " <>
              "before it: build the page with `use ScrawlyWeb.Page` (or attach the middleware)"
    end
  end

  defp accent_or_default(nil), do: :purple
  defp accent_or_default(a) when is_atom(a) and a in @accents, do: a

  defp accent_or_default(a) when is_binary(a) do
    try do
      atom = String.to_existing_atom(a)
      if atom in @accents, do: atom, else: :purple
    rescue
      _ -> :purple
    end
  end

  defp accent_or_default(_), do: :purple

  # Passwords and recovery codes never enter the state (it is rendered into the
  # HTML and snapshotted for Back/Forward): those inputs are not synchronized
  # (no value binding, no $change), the $submit action reads them from the
  # event, and every failure, hide and switch empties them in the DOM
  # (clear_secret_fields/1).
  defp put_auth_defaults(component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:show_accent_picker, false)
    |> put_state(:login_email, "")
    |> put_state(:register_email, "")
    |> put_state(:auth_error, nil)
    |> put_reset_defaults()
    |> put_state(:recovery_code, nil)
    |> put_state(:recovery_code_saved, false)
    |> put_state(:recovery_code_copied, false)
    |> put_state(:pending_auth, nil)
  end

  defp put_reset_defaults(component) do
    component
    |> put_state(:show_reset_modal, false)
    |> put_state(:reset_email, "")
    |> put_state(:reset_error, nil)
  end

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html
      lang="en"
      data-theme={if(@dark_mode, do: "dark", else: "light")}
      data-accent={to_string(@accent)}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Scrawly — draw, guess, quietly</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Geist:wght@300;400;500;600&family=Geist+Mono:wght@400;500&display=swap"
          rel="stylesheet" />
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
        <script type="text/javascript" src="/phoenix.min.js"></script>
        <script type="text/javascript" src="/game_socket.js"></script>
        <script type="text/javascript" src="/chat_scroll.js"></script>
        <Runtime />
      </head>
      <body>
        <script>Hologram.dispatchAction("layout_shown", "layout", \{mount_id: "{@mount_id}"\});</script>
        <AvatarDefs />
        <header class="app-header">
          <div class="nav-glow" aria-hidden="true">
            <span class="blob"></span>
          </div>
          <div class="app-header-inner">
            <div class="row header-left">
              <Link to={ScrawlyWeb.Pages.HomePage}>
                <div class="brand">
                  <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                    <path
                      d="M2 18 L7 6 L10 18 L14 6 L17 18 L22 6"
                      stroke="currentColor"
                      stroke-width="2.4"
                      stroke-linecap="square"
                      stroke-linejoin="miter" />
                  </svg>
                  <div class="brand-name">scrawly<em>v1</em></div>
                </div>
              </Link>
              <nav class="header-nav">
                {%if @authenticated}
                  <Link to={ScrawlyWeb.Pages.PastGamesPage}>
                    <span class="header-link">history</span>
                  </Link>
                {/if}
              </nav>
            </div>

            <div class="header-actions" style="position: relative;">
              <span class="chip mono">
                <span style="width: 6px; height: 6px; border-radius: 999px; background: var(--success); display: inline-block;"></span>
                {@online_count} online
              </span>

              <span
                style="display: contents;"
                $click_outside={action: if(@show_accent_picker, do: :close_accent_picker), target: "layout"}>
                <button
                  $click={action: :toggle_accent_picker, target: "layout"}
                  class="icon-btn"
                  title="Choose accent">
                  <span style="width: 14px; height: 14px; border-radius: 999px; background: var(--accent); display: inline-block; border: 1px solid var(--hairline-2);"></span>
                </button>
                {%if @show_accent_picker}
                  <window $key_down.escape={action: :close_accent_picker, target: "layout"} />
                  <div class="accent-popover">
                    <div class="section-label" style="margin-bottom: 8px;">theme</div>
                    <div class="seg" style="margin-bottom: 12px;">
                      <button
                        type="button"
                        class={if(!@dark_mode, do: "active", else: "")}
                        $click={action: :set_theme, target: "layout", params: %{mode: "light"}}>light</button>
                      <button
                        type="button"
                        class={if(@dark_mode, do: "active", else: "")}
                        $click={action: :set_theme, target: "layout", params: %{mode: "dark"}}>dark</button>
                    </div>
                    <div class="section-label" style="margin-bottom: 8px;">accent</div>
                    <div class="accent-row">
                      <button
                        type="button"
                        class={if(@accent == :purple, do: "accent-dot active", else: "accent-dot")}
                        style="background: #8b5cf6;"
                        title="hologram"
                        $click={action: :set_accent, target: "layout", params: %{name: "purple"}}></button>
                      <button
                        type="button"
                        class={if(@accent == :yellow, do: "accent-dot active", else: "accent-dot")}
                        style="background: #ffbd59;"
                        title="ash"
                        $click={action: :set_accent, target: "layout", params: %{name: "yellow"}}></button>
                      <button
                        type="button"
                        class={if(@accent == :orange, do: "accent-dot active", else: "accent-dot")}
                        style="background: #fd4f00;"
                        title="phoenix"
                        $click={action: :set_accent, target: "layout", params: %{name: "orange"}}></button>
                    </div>
                  </div>
                {/if}
              </span>

              <button
                $click={action: :toggle_theme, target: "layout"}
                class="icon-btn"
                title={if(@dark_mode, do: "Switch to light mode", else: "Switch to dark mode")}>
                {%if @dark_mode}
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
                    <circle cx="12" cy="12" r="4" />
                    <path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" stroke-linecap="round" />
                  </svg>
                {%else}
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
                    <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" stroke-linejoin="round" />
                  </svg>
                {/if}
              </button>

              {%if @authenticated}
                <Link to={ScrawlyWeb.Pages.ProfilePage}>
                  <span class="user-chip" title="Edit profile">
                    <Avatar avatar_id={@avatar_id} color={@avatar_color} size="xs" />
                    <span class="user-chip-name">{@username}</span>
                  </span>
                </Link>
                <button
                  type="button"
                  class="header-link"
                  title="Sign out"
                  $click={action: :sign_out, target: "layout"}>sign out</button>
              {%else}
                <button class="app-btn app-btn-ghost app-btn-sm" $click={action: :show_login, target: "layout"}>log in</button>
                <button class="app-btn app-btn-ink app-btn-sm" $click={action: :show_register, target: "layout"}>register</button>
              {/if}
            </div>
          </div>
        </header>

        {%if @show_login_modal}
          <window $key_down.escape={action: :hide_auth_modal, target: "layout"} />
          <div class="scrim">
            <form
              class="app-modal"
              style="max-width: 400px;"
              $submit={action: :submit_login, target: "layout"}
              $key_down.n.stop_propagation={action: :noop, target: "layout"}>
              <div class="app-modal-head">
                <div>
                  <h3>log in</h3>
                  <div class="sub">welcome back.</div>
                </div>
                <button type="button" class="icon-btn" $click={action: :hide_auth_modal, target: "layout"}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round" /></svg>
                </button>
              </div>
              <div class="app-modal-body">
                {%if @auth_error}
                  <div style="color: var(--danger); font-size: 12px;">{@auth_error}</div>
                {/if}
                <div>
                  <label class="field-label">email</label>
                  <input
                    type="email"
                    name="email"
                    placeholder="you@example.com"
                    class="app-input"
                    value={@login_email}
                    $change={action: :update_login_email, target: "layout"} />
                </div>
                <div>
                  <label class="field-label">password</label>
                  <input
                    type="password"
                    name="password"
                    autocomplete="current-password"
                    placeholder="••••••••"
                    class="app-input"
                    data-secret="1" />
                </div>
              </div>
              <div class="app-modal-foot" style="flex-direction: column; align-items: stretch;">
                <button type="submit" class="app-btn app-btn-primary" style="width: 100%;">
                  log in
                </button>
                <div class="mono" style="font-size: 11px; color: var(--muted); text-align: center;">
                  no account? <button type="button" style="background: none; border: 0; color: var(--ink); cursor: pointer; font: inherit;" $click={action: :switch_to_register, target: "layout"}>register</button>
                  · <button type="button" style="background: none; border: 0; color: var(--ink); cursor: pointer; font: inherit;" $click={action: :show_reset, target: "layout"}>forgot password?</button>
                </div>
              </div>
            </form>
          </div>
        {/if}

        {%if @show_reset_modal}
          <window $key_down.escape={action: :hide_auth_modal, target: "layout"} />
          <div class="scrim">
            <form
              class="app-modal"
              style="max-width: 400px;"
              $submit={action: :submit_reset, target: "layout"}
              $key_down.n.stop_propagation={action: :noop, target: "layout"}>
              <div class="app-modal-head">
                <div>
                  <h3>reset password</h3>
                  <div class="sub">use the recovery code you saved when you registered.</div>
                </div>
                <button type="button" class="icon-btn" $click={action: :hide_auth_modal, target: "layout"}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round" /></svg>
                </button>
              </div>
              <div class="app-modal-body">
                {%if @reset_error}
                  <div style="color: var(--danger); font-size: 12px;">{@reset_error}</div>
                {/if}
                <div>
                  <label class="field-label">email</label>
                  <input
                    type="email"
                    name="email"
                    autocomplete="email"
                    placeholder="you@example.com"
                    class="app-input"
                    value={@reset_email}
                    $change={action: :update_reset_email, target: "layout"} />
                </div>
                <div>
                  <label class="field-label">recovery code</label>
                  <input
                    type="text"
                    name="recovery_code"
                    autocomplete="off"
                    spellcheck="false"
                    placeholder="XXXX-XXXX-XXXX-XXXX-XXXX"
                    class="app-input mono"
                    data-secret="1" />
                </div>
                <div>
                  <label class="field-label">new password</label>
                  <input
                    type="password"
                    name="new_password"
                    autocomplete="new-password"
                    placeholder="at least 8 characters"
                    class="app-input"
                    data-secret="1" />
                </div>
                <div>
                  <label class="field-label">confirm new password</label>
                  <input
                    type="password"
                    name="new_password_confirmation"
                    autocomplete="new-password"
                    placeholder="repeat new password"
                    class="app-input"
                    data-secret="1" />
                </div>
              </div>
              <div class="app-modal-foot" style="flex-direction: column; align-items: stretch;">
                <button type="submit" class="app-btn app-btn-primary" style="width: 100%;">
                  set new password
                </button>
                <div class="mono" style="font-size: 11px; color: var(--muted); text-align: center;">
                  remembered it? <button type="button" style="background: none; border: 0; color: var(--ink); cursor: pointer; font: inherit;" $click={action: :switch_to_login, target: "layout"}>log in</button>
                </div>
              </div>
            </form>
          </div>
        {/if}

        {%if @recovery_code}
          <RecoveryCodePanel code={@recovery_code} saved={@recovery_code_saved} copied={@recovery_code_copied} />
        {/if}

        {%if @show_register_modal}
          <window $key_down.escape={action: :hide_auth_modal, target: "layout"} />
          <div class="scrim">
            <form
              class="app-modal"
              style="max-width: 400px;"
              $submit={action: :submit_register, target: "layout"}
              $key_down.n.stop_propagation={action: :noop, target: "layout"}>
              <div class="app-modal-head">
                <div>
                  <h3>register</h3>
                  <div class="sub">let's get you a handle.</div>
                </div>
                <button type="button" class="icon-btn" $click={action: :hide_auth_modal, target: "layout"}>
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round" /></svg>
                </button>
              </div>
              <div class="app-modal-body">
                {%if @auth_error}
                  <div style="color: var(--danger); font-size: 12px;">{@auth_error}</div>
                {/if}
                <div>
                  <label class="field-label">email</label>
                  <input
                    type="email"
                    name="email"
                    placeholder="you@example.com"
                    class="app-input"
                    value={@register_email}
                    $change={action: :update_register_email, target: "layout"} />
                </div>
                <div>
                  <label class="field-label">password</label>
                  <input
                    type="password"
                    name="password"
                    autocomplete="new-password"
                    placeholder="••••••••"
                    class="app-input"
                    data-secret="1" />
                </div>
              </div>
              <div class="app-modal-foot" style="flex-direction: column; align-items: stretch;">
                <button type="submit" class="app-btn app-btn-primary" style="width: 100%;">
                  create account
                </button>
                <div class="mono" style="font-size: 11px; color: var(--muted); text-align: center;">
                  have an account? <button type="button" style="background: none; border: 0; color: var(--ink); cursor: pointer; font: inherit;" $click={action: :switch_to_login, target: "layout"}>log in</button>
                </div>
              </div>
            </form>
          </div>
        {/if}

        <div id="hologram-page">
          <slot />
        </div>

        <footer class="app-footer">
          <div class="footer-content">
            <div class="footer-wordmark">scrawly</div>
            <div class="footer-credits">
              <span><span class="swatch h"></span><b>hologram</b></span>
              <span class="footer-sep">·</span>
              <span><span class="swatch a"></span><b>ash</b></span>
              <span class="footer-sep">·</span>
              <span><span class="swatch p"></span><b>phoenix</b></span>
            </div>
          </div>
          <div class="footer-glow" aria-hidden="true">
            <span class="blob"></span>
          </div>
        </footer>
      </body>
    </html>
    """
  end

  # ── Online presence ──────────────────────────────────────────────
  #
  # "N online" is pushed (`:online_count_updated` on `:online`, from
  # ScrawlyWeb.OnlineTracker); the tab only keeps itself counted: a
  # `:presence_ping` command every 20 s, from a self-rescheduling chain that
  # init starts. The chain carries the `ping_gen` it was started with and
  # stops as soon as that is not the layout's current one, so a stale chain
  # (one that outlived its layout state) can never run beside the current
  # one. Hologram 0.12 drops a left page's queued actions anyway.
  #
  # A Back/Forward restore brings the layout back from a snapshot without init
  # or queued actions, i.e. without a chain, and with the count it was left
  # with. The template's inline script dispatches :layout_shown each time this
  # layout instance's markup is put into the document (Hologram runs the
  # inline scripts a patch inserts and keys them by their text, hence
  # @mount_id): the first time it only marks the instance, a later one is a
  # restore, which pings at once (the reply carries the current count) and
  # starts a new chain.
  #
  # Fallback: `:online_count_updated` restarts the chain once the last ping
  # (browser monotonic time) is over 30 s old, or newer than now (a snapshot
  # from an earlier document). `last_ping_at` is nil until the first ping; a
  # count update then records a baseline instead, so a chain that never fired
  # is caught 30 s later too.

  def action(:layout_shown, _params, component) do
    if component.state.layout_shown?,
      do: ping(component, component.state.ping_gen + 1, resync: true),
      else: put_state(component, :layout_shown?, true)
  end

  def action(:presence_ping, %{gen: gen}, component) do
    if gen == component.state.ping_gen, do: ping(component, gen), else: component
  end

  def action(:online_count_updated, %{count: count}, component) do
    component = put_state(component, :online_count, count)
    now = System.monotonic_time(:millisecond)

    case component.state.last_ping_at do
      nil ->
        put_state(component, :last_ping_at, now)

      at when now - at > @ping_dead_ms or now < at ->
        ping(component, component.state.ping_gen + 1)

      _alive ->
        component
    end
  end

  # ── Theme & Accent actions ────────────────────────────────────────

  def action(:toggle_theme, _params, component) do
    new_mode = not component.state.dark_mode

    component
    |> put_state(:dark_mode, new_mode)
    |> put_command(:save_theme, %{dark_mode: new_mode})
  end

  def action(:set_theme, %{mode: mode}, component) do
    dark = mode == "dark"

    component
    |> put_state(:dark_mode, dark)
    |> put_command(:save_theme, %{dark_mode: dark})
  end

  def action(:toggle_accent_picker, _params, component) do
    put_state(component, :show_accent_picker, not component.state.show_accent_picker)
  end

  # Escape and $click_outside. The toggle and the popover share the
  # `display: contents` span that carries $click_outside (so .header-actions
  # stays their layout box and the popover's containing block): a click on the
  # toggle while open is "inside", and the toggle alone closes it. The binding
  # resolves to nil while the popover is closed, which disables it.
  def action(:close_accent_picker, _params, component) do
    put_state(component, :show_accent_picker, false)
  end

  def action(:set_accent, %{name: name}, component) do
    atom = String.to_existing_atom(name)

    component
    |> put_state(:accent, atom)
    |> put_command(:save_accent, %{accent: name})
  end

  # Target of the typing guards on the layout's forms
  # (`$key_down.n.stop_propagation`): it stops a page's `<window>` N shortcut
  # while the user types here. A guard needs a real operation; a nil one
  # stops nothing.
  def action(:noop, _params, component), do: component

  # ── Auth actions ───────────────────────────────────────────────

  def action(:show_login, _params, component) do
    component
    |> put_state(:show_login_modal, true)
    |> put_state(:show_register_modal, false)
    |> put_state(:auth_error, nil)
  end

  def action(:show_register, _params, component) do
    component
    |> put_state(:show_register_modal, true)
    |> put_state(:show_login_modal, false)
    |> put_state(:auth_error, nil)
  end

  def action(:hide_auth_modal, _params, component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:login_email, "")
    |> put_state(:register_email, "")
    |> put_state(:auth_error, nil)
    |> put_reset_defaults()
    |> clear_secret_fields()
  end

  def action(:switch_to_register, _params, component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, true)
    |> put_state(:auth_error, nil)
    |> clear_secret_fields()
  end

  def action(:switch_to_login, _params, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_register_modal, false)
    |> put_state(:show_login_modal, true)
    |> put_state(:auth_error, nil)
    |> clear_secret_fields()
  end

  def action(:update_login_email, %{event: %{value: val}}, component) do
    put_state(component, :login_email, val)
  end

  def action(:update_register_email, %{event: %{value: val}}, component) do
    put_state(component, :register_email, val)
  end

  # The password comes from the submit event (see put_auth_defaults/1).
  def action(:submit_login, params, component) do
    put_command(component, :login, %{
      email: component.state.login_email,
      password: form_value(params, "password")
    })
  end

  def action(:submit_register, params, component) do
    put_command(component, :register, %{
      email: component.state.register_email,
      password: form_value(params, "password")
    })
  end

  # Signed in (or registered): the page the user is on loads again, now with
  # the session (logging in from history shows their history). A reload, not
  # put_page: the page's server-side init must run for the new identity, and
  # a same-URL navigation would restore the snapshot of the signed-out page.
  def action(:auth_success, %{username: username} = params, component) do
    ~JS"""
    window.location.reload();
    """

    component
    |> put_state(:authenticated, true)
    |> put_state(:username, username)
    |> put_state(:avatar_id, Map.get(params, :avatar_id) || AvatarDefs.default_id())
    |> put_state(:avatar_color, Map.get(params, :avatar_color) || AvatarDefs.default_color())
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:login_email, "")
    |> put_state(:register_email, "")
    |> put_state(:auth_error, nil)
  end

  def action(:auth_error, %{message: message}, component) do
    component
    |> put_state(:auth_error, message)
    |> clear_secret_fields()
  end

  # The header's "sign out" (a command, so no other site can trigger it the
  # way it could a GET link). Its reply loads the home page afresh.
  def action(:sign_out, _params, component), do: put_command(component, :sign_out)

  def action(:signed_out, _params, component) do
    ~JS"""
    if (window.location.pathname === "/") { window.location.reload(); } else { window.location.assign("/"); }
    """

    component
  end

  # A denied layout command (ScrawlyWeb.Auth.deny/3) changes nothing here.
  def action(:command_denied, _params, component), do: component

  # ── Forgot password (recovery code) ────────────────────────────

  def action(:show_reset, _params, component) do
    component
    |> put_reset_defaults()
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:show_reset_modal, true)
    |> put_state(:reset_email, component.state.login_email)
    |> put_state(:auth_error, nil)
    |> clear_secret_fields()
  end

  def action(:update_reset_email, %{event: %{value: val}}, component) do
    put_state(component, :reset_email, val)
  end

  def action(:submit_reset, params, component) do
    component
    |> put_state(:reset_error, nil)
    |> put_command(:reset_password, %{
      email: component.state.reset_email,
      recovery_code: form_value(params, "recovery_code"),
      password: form_value(params, "new_password"),
      password_confirmation: form_value(params, "new_password_confirmation")
    })
  end

  def action(:recovery_reset_failed, %{message: message}, component) do
    component
    |> put_state(:reset_error, message)
    |> clear_secret_fields()
  end

  # ── Recovery code panel (after register or reset) ───────────────
  # The session is already signed in; :auth_success (header + reload)
  # waits until the user has seen the code and pressed continue.

  def action(:show_recovery_code, %{code: code} = params, component) do
    component
    |> put_auth_defaults()
    |> put_state(:recovery_code, code)
    |> put_state(:pending_auth, %{
      username: Map.get(params, :username),
      avatar_id: Map.get(params, :avatar_id),
      avatar_color: Map.get(params, :avatar_color)
    })
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
    pending = component.state.pending_auth

    component =
      component
      |> put_state(:recovery_code, nil)
      |> put_state(:recovery_code_saved, false)
      |> put_state(:recovery_code_copied, false)
      |> put_state(:pending_auth, nil)

    if pending, do: put_action(component, :auth_success, pending), else: component
  end

  # Receives live updates from the profile page so the navbar reflects
  # the new handle / avatar without a full page reload.
  def action(:profile_updated, params, component) do
    component
    |> put_state(:username, Map.get(params, :username) || component.state.username)
    |> put_state(:avatar_id, Map.get(params, :avatar_id) || component.state.avatar_id)
    |> put_state(:avatar_color, Map.get(params, :avatar_color) || component.state.avatar_color)
  end

  # A field of a $submit event (string keys: the browser's form data).
  defp form_value(params, name) do
    event = if is_map(params), do: Map.get(params, :event)
    value = if is_map(event), do: Map.get(event, name)
    if is_binary(value), do: value, else: ""
  end

  # Empties every password / recovery-code input on the page (`data-secret`):
  # they are not synchronized, so the state can't do it.
  defp clear_secret_fields(component) do
    ~JS"""
    document.querySelectorAll("input[data-secret]").forEach(function (el) { el.value = ""; });
    """

    component
  end

  # Pings now and schedules the next ping of chain `gen`, which becomes the
  # current one. `resync: true` asks the command to reply with the count.
  defp ping(component, gen, params \\ []) do
    component
    |> put_state(:ping_gen, gen)
    |> put_state(:last_ping_at, System.monotonic_time(:millisecond))
    |> put_command(:presence_ping, params)
    |> put_action(name: :presence_ping, params: %{gen: gen}, delay: @ping_ms)
  end

  # ── Commands ─────────────────────────────────────────────────────

  # Every clause reads its params through ScrawlyWeb.CommandParams (or a
  # matching case) and the last one denies unknown names: a forged command
  # gets :command_denied, never an exception.
  def command(:presence_ping, params, server) do
    OnlineTracker.touch(ScrawlyWeb.Auth.actor_key(server))

    if is_map(params) and Map.get(params, :resync) == true,
      do: put_action(server, :online_count_updated, count: OnlineTracker.count()),
      else: server
  end

  # The layout's LoadCurrentUser has checked the session (a revoked cookie
  # can't write to the account); Auth loads the user from the stashed id.
  def command(:save_theme, params, server) do
    case params do
      %{dark_mode: dark_mode} when is_boolean(dark_mode) ->
        server = put_session(server, :dark_mode, dark_mode)

        case ScrawlyWeb.Auth.current_user(server) do
          {:ok, user} -> Scrawly.Accounts.update_dark_mode(user, dark_mode)
          {:error, :unauthenticated} -> :ok
        end

        server

      _ ->
        CommandParams.deny_invalid(server, :save_theme)
    end
  end

  def command(:save_accent, params, server) do
    case Enum.find(@accents, &(Atom.to_string(&1) == CommandParams.string(params, :accent))) do
      nil ->
        CommandParams.deny_invalid(server, :save_accent)

      accent ->
        server = put_session(server, :accent_color, Atom.to_string(accent))

        case ScrawlyWeb.Auth.current_user(server) do
          {:ok, user} -> Scrawly.Accounts.update_accent_color(user, accent)
          {:error, :unauthenticated} -> :ok
        end

        server
    end
  end

  # Throttled per email and per client IP inside the sign-in action
  # (ScrawlyWeb.Auth.sign_in/3, shared with HomePage :sign_in).
  def command(:login, params, server) do
    case ScrawlyWeb.Auth.sign_in(
           server,
           CommandParams.string(params, :email),
           CommandParams.string(params, :password)
         ) do
      {:ok, user, server} ->
        server
        |> put_session(:dark_mode, user.dark_mode)
        |> put_session(:accent_color, to_string(user.accent_color || :purple))
        |> put_action(:auth_success,
          username: user.username,
          avatar_id: user.avatar_id,
          avatar_color: user.avatar_color
        )

      {:error, :throttled} ->
        put_action(server, :auth_error,
          message: "Too many sign-in attempts. Try again in a few minutes."
        )

      {:error, :invalid} ->
        put_action(server, :auth_error, message: "Incorrect email or password")
    end
  end

  def command(:register, params, server) do
    with {:ok, %{email: email, password: password}} <-
           CommandParams.strings(params, [:email, :password]),
         {:ok, user} <- Scrawly.Accounts.register_with_password(email, password) do
      # :auth_success follows once the code has been seen (:close_recovery_code).
      server
      |> ScrawlyWeb.Auth.put_session_user(user, user.__metadata__.token)
      |> put_action(:show_recovery_code,
        code: user.__metadata__.recovery_code,
        username: user.username,
        avatar_id: user.avatar_id,
        avatar_color: user.avatar_color
      )
    else
      _error ->
        put_action(server, :auth_error,
          message: "Registration failed. Email may already be in use."
        )
    end
  end

  def command(:reset_password, params, server) when is_map(params) do
    ScrawlyWeb.Recovery.reset_password(params, server)
  end

  def command(:sign_out, _params, server) do
    server
    |> ScrawlyWeb.Auth.sign_out()
    |> put_action(:signed_out)
  end

  def command(name, _params, server), do: CommandParams.deny_unknown(server, name)
end
