defmodule ScrawlyWeb.Layouts.AppLayout do
  use Hologram.Component

  alias Hologram.UI.Runtime
  alias Hologram.UI.Link

  @accents [:purple, :yellow, :orange]

  def init(_props, component, server) do
    user_id = get_session(server, :user_id)
    session_dark = get_session(server, :dark_mode) == true
    session_accent = get_session(server, :accent_color) |> accent_or_default()

    case user_id do
      nil ->
        component
        |> put_state(:authenticated, false)
        |> put_state(:username, nil)
        |> put_state(:user_id, nil)
        |> put_state(:dark_mode, session_dark)
        |> put_state(:accent, session_accent)
        |> put_auth_defaults()
        |> put_state(:online_count, ScrawlyWeb.Presence.online_count())
        |> put_action(name: :tick_online, delay: 5000)

      id ->
        case Ash.get(Scrawly.Accounts.User, id) do
          {:ok, user} ->
            user_accent =
              case user.accent_color do
                a when a in @accents -> a
                _ -> session_accent
              end

            component
            |> put_state(:authenticated, true)
            |> put_state(:username, user.username)
            |> put_state(:user_id, id)
            |> put_state(:dark_mode, user.dark_mode || session_dark)
            |> put_state(:accent, user_accent)
            |> put_auth_defaults()
            |> put_state(:online_count, ScrawlyWeb.Presence.online_count())
            |> put_action(name: :tick_online, delay: 5000)

          {:error, _} ->
            component
            |> put_state(:authenticated, false)
            |> put_state(:username, nil)
            |> put_state(:user_id, nil)
            |> put_state(:dark_mode, session_dark)
            |> put_state(:accent, session_accent)
            |> put_auth_defaults()
            |> put_state(:online_count, ScrawlyWeb.Presence.online_count())
            |> put_action(name: :tick_online, delay: 5000)
        end
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

  defp put_auth_defaults(component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:show_accent_picker, false)
    |> put_state(:login_email, "")
    |> put_state(:login_password, "")
    |> put_state(:register_email, "")
    |> put_state(:register_password, "")
    |> put_state(:auth_error, nil)
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
        <Runtime />
      </head>
      <body>
        <header class="app-header">
          <div class="nav-glow" aria-hidden="true">
            <span class="blob"></span>
          </div>
          <div class="app-header-inner">
            <div class="row" style="gap: 32px;">
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

              <button
                $click={action: :toggle_accent_picker, target: "layout"}
                class="icon-btn"
                title="Choose accent">
                <span style="width: 14px; height: 14px; border-radius: 999px; background: var(--accent); display: inline-block; border: 1px solid var(--hairline-2);"></span>
              </button>

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
                <div class="user-chip">
                  <span class="avatar">{String.upcase(String.slice(@username || "?", 0..0))}</span>
                  <span>{@username}</span>
                </div>
                <a href="/sign-out" class="header-link" title="Sign out">sign out</a>
              {%else}
                <button class="app-btn app-btn-ghost app-btn-sm" $click={action: :show_login, target: "layout"}>log in</button>
                <button class="app-btn app-btn-ink app-btn-sm" $click={action: :show_register, target: "layout"}>register</button>
              {/if}

              {%if @show_accent_picker}
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
            </div>
          </div>
        </header>

        {%if @show_login_modal}
          <div class="scrim">
            <form
              class="app-modal"
              style="max-width: 400px;"
              $submit={action: :submit_login, target: "layout"}>
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
                    $input={action: :update_login_email, target: "layout"} />
                </div>
                <div>
                  <label class="field-label">password</label>
                  <input
                    type="password"
                    name="password"
                    placeholder="••••••••"
                    class="app-input"
                    value={@login_password}
                    $input={action: :update_login_password, target: "layout"} />
                </div>
              </div>
              <div class="app-modal-foot" style="flex-direction: column; align-items: stretch;">
                <button type="submit" class="app-btn app-btn-primary" style="width: 100%;">
                  log in
                </button>
                <div class="mono" style="font-size: 11px; color: var(--muted); text-align: center;">
                  no account? <button type="button" style="background: none; border: 0; color: var(--ink); cursor: pointer; font: inherit;" $click={action: :switch_to_register, target: "layout"}>register</button>
                </div>
              </div>
            </form>
          </div>
        {/if}

        {%if @show_register_modal}
          <div class="scrim">
            <form
              class="app-modal"
              style="max-width: 400px;"
              $submit={action: :submit_register, target: "layout"}>
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
                    $input={action: :update_register_email, target: "layout"} />
                </div>
                <div>
                  <label class="field-label">password</label>
                  <input
                    type="password"
                    name="password"
                    placeholder="••••••••"
                    class="app-input"
                    value={@register_password}
                    $input={action: :update_register_password, target: "layout"} />
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

  def action(:tick_online, _params, component) do
    put_command(component, :read_online_count, %{})
  end

  def action(:online_count_updated, %{count: count}, component) do
    component
    |> put_state(:online_count, count)
    |> put_action(name: :tick_online, delay: 5000)
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

  def action(:set_accent, %{name: name}, component) do
    atom = String.to_existing_atom(name)

    component
    |> put_state(:accent, atom)
    |> put_command(:save_accent, %{accent: name})
  end

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
    |> put_state(:login_password, "")
    |> put_state(:register_email, "")
    |> put_state(:register_password, "")
    |> put_state(:auth_error, nil)
  end

  def action(:switch_to_register, _params, component) do
    component
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, true)
    |> put_state(:auth_error, nil)
  end

  def action(:switch_to_login, _params, component) do
    component
    |> put_state(:show_register_modal, false)
    |> put_state(:show_login_modal, true)
    |> put_state(:auth_error, nil)
  end

  def action(:update_login_email, %{event: %{value: val}}, component) do
    put_state(component, :login_email, val)
  end

  def action(:update_login_password, %{event: %{value: val}}, component) do
    put_state(component, :login_password, val)
  end

  def action(:update_register_email, %{event: %{value: val}}, component) do
    put_state(component, :register_email, val)
  end

  def action(:update_register_password, %{event: %{value: val}}, component) do
    put_state(component, :register_password, val)
  end

  def action(:submit_login, _params, component) do
    put_command(component, :login, %{
      email: component.state.login_email,
      password: component.state.login_password
    })
  end

  def action(:submit_register, _params, component) do
    put_command(component, :register, %{
      email: component.state.register_email,
      password: component.state.register_password
    })
  end

  def action(:auth_success, %{username: username}, component) do
    component
    |> put_state(:authenticated, true)
    |> put_state(:username, username)
    |> put_state(:show_login_modal, false)
    |> put_state(:show_register_modal, false)
    |> put_state(:login_email, "")
    |> put_state(:login_password, "")
    |> put_state(:register_email, "")
    |> put_state(:register_password, "")
    |> put_state(:auth_error, nil)
    |> put_page(ScrawlyWeb.Pages.HomePage)
  end

  def action(:auth_error, %{message: message}, component) do
    put_state(component, :auth_error, message)
  end

  # ── Commands ─────────────────────────────────────────────────────

  def command(:read_online_count, _params, server) do
    put_action(server, :online_count_updated, count: ScrawlyWeb.Presence.online_count())
  end

  def command(:save_theme, %{dark_mode: dark_mode}, server) do
    server = put_session(server, :dark_mode, dark_mode)

    user_id = get_session(server, :user_id)

    if user_id do
      case Ash.get(Scrawly.Accounts.User, user_id) do
        {:ok, user} -> Scrawly.Accounts.update_dark_mode(user, dark_mode)
        _ -> :ok
      end
    end

    server
  end

  def command(:save_accent, %{accent: accent}, server) do
    atom = String.to_existing_atom(accent)
    server = put_session(server, :accent_color, accent)

    user_id = get_session(server, :user_id)

    if user_id do
      case Ash.get(Scrawly.Accounts.User, user_id) do
        {:ok, user} -> Scrawly.Accounts.update_accent_color(user, atom)
        _ -> :ok
      end
    end

    server
  end

  def command(:login, %{email: email, password: password}, server) do
    strategy = AshAuthentication.Info.strategy!(Scrawly.Accounts.User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{email: email, password: password}) do
      {:ok, user} ->
        server
        |> put_session(:user_id, user.id)
        |> put_session(:user_token, user.__metadata__.token)
        |> put_session(:dark_mode, user.dark_mode)
        |> put_session(:accent_color, to_string(user.accent_color || :purple))
        |> put_action(:auth_success, username: user.username)

      {:error, _} ->
        put_action(server, :auth_error, message: "Incorrect email or password")
    end
  end

  def command(:register, %{email: email, password: password}, server) do
    strategy = AshAuthentication.Info.strategy!(Scrawly.Accounts.User, :password)

    case AshAuthentication.Strategy.action(strategy, :register, %{
           email: email,
           password: password
         }) do
      {:ok, user} ->
        server
        |> put_session(:user_id, user.id)
        |> put_session(:user_token, user.__metadata__.token)
        |> put_action(:auth_success, username: user.username)

      {:error, _} ->
        put_action(server, :auth_error,
          message: "Registration failed. Email may already be in use."
        )
    end
  end
end
