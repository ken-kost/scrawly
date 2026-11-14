defmodule ScrawlyWeb.Pages.ProfilePage do
  use Hologram.Page
  use Hologram.JS

  js_import :copyRecoveryCode, from: "../components/recovery_code.mjs"
  js_import :downloadRecoveryCode, from: "../components/recovery_code.mjs"

  route "/profile"
  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.{Avatar, AvatarDefs, RecoveryCodePanel}

  def init(_params, component, server) do
    case get_session(server, :user_id) do
      nil ->
        put_page(component, ScrawlyWeb.Pages.HomePage)

      user_id ->
        case Ash.get(Scrawly.Accounts.User, user_id) do
          {:ok, user} ->
            component
            |> put_state(:authenticated, true)
            |> put_state(:user_id, user.id)
            |> put_state(:email, to_string(user.email))
            |> put_state(:username, user.username || "")
            |> put_state(:avatar_id, user.avatar_id || AvatarDefs.default_id())
            |> put_state(:avatar_color, user.avatar_color || AvatarDefs.default_color())
            |> put_state(:current_password, "")
            |> put_state(:new_password, "")
            |> put_state(:new_password_confirmation, "")
            |> put_state(:profile_message, nil)
            |> put_state(:profile_error, nil)
            |> put_state(:password_message, nil)
            |> put_state(:password_error, nil)
            |> put_state(:avatars, AvatarDefs.avatars())
            |> put_state(:color_choices, Enum.map(1..24, &Integer.to_string/1))
            |> put_state(:recovery_status, ScrawlyWeb.Recovery.status(user))
            |> put_state(
              :recovery_generated_label,
              ScrawlyWeb.Recovery.generated_label(user.recovery_code_generated_at)
            )
            |> put_state(:recovery_password, "")
            |> put_state(:recovery_error, nil)
            |> put_state(:recovery_message, nil)
            |> put_state(:recovery_code, nil)
            |> put_state(:recovery_code_saved, false)

          _ ->
            put_page(component, ScrawlyWeb.Pages.HomePage)
        end
    end
  end

  def template do
    ~HOLO"""
    <div class="page page-narrow">
      <section class="hero" style="padding-bottom: 24px;">
        <div>
          <h1 style="font-size: 44px;">profile.</h1>
          <p class="sub" style="margin-top: 10px;">your handle, your password, your tiny face.</p>
        </div>
        <div class="profile-hero-avatar">
          <Avatar avatar_id={@avatar_id} color={@avatar_color} size="xl" />
          <div class="profile-hero-meta">
            <div class="section-label">signed in as</div>
            <div class="profile-email mono">{@email}</div>
          </div>
        </div>
      </section>

      <div class="profile-grid">
        <section class="surface profile-card">
          <div class="section-header" style="border-bottom: 1px solid var(--hairline); padding-bottom: 12px; margin-bottom: 18px;">
            <h2>identity</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">handle</span>
          </div>

          <form $submit={:save_profile}>
            <label class="field-label">username</label>
            <input
              class="app-input"
              type="text"
              name="username"
              value={@username}
              placeholder="how the lobby knows you"
              minlength="2"
              maxlength="20"
              $input={:update_username} />

            <div style="margin-top: 18px;">
              <div class="row" style="justify-content: space-between; align-items: center;">
                <label class="field-label" style="margin: 0;">avatar</label>
                <span class="mono" style="font-size: 11px; color: var(--muted);">{String.upcase(AvatarDefs.name_for(@avatar_id))}</span>
              </div>

              <div class="avatar-grid">
                {%for {a_id, _name} <- @avatars}
                  <button
                    type="button"
                    class={"avatar-grid-cell" <> if(@avatar_id == a_id, do: " sel", else: "")}
                    data-c={@avatar_color}
                    $click={:pick_avatar, id: a_id}>
                    <svg viewBox="0 0 100 100"><use href={"#" <> a_id} /></svg>
                  </button>
                {/for}
              </div>

              <div style="margin-top: 14px;">
                <label class="field-label">tile color</label>
                <div class="avatar-swatch-row">
                  {%for c <- @color_choices}
                    <button
                      type="button"
                      class={"avatar-swatch" <> if(@avatar_color == c, do: " sel", else: "")}
                      data-c={c}
                      $click={:pick_color, color: c}></button>
                  {/for}
                </div>
              </div>
            </div>

            {%if @profile_error}
              <div class="form-error">{@profile_error}</div>
            {/if}
            {%if @profile_message}
              <div class="form-success">{@profile_message}</div>
            {/if}

            <div style="margin-top: 20px; display: flex; gap: 8px; justify-content: flex-end;">
              <button type="submit" class="app-btn app-btn-primary">save profile</button>
            </div>
          </form>
        </section>

        <section class="surface profile-card">
          <div class="section-header" style="border-bottom: 1px solid var(--hairline); padding-bottom: 12px; margin-bottom: 18px;">
            <h2>password</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">change</span>
          </div>

          <form $submit={:save_password}>
            <label class="field-label">current password</label>
            <input
              class="app-input"
              type="password"
              name="current_password"
              autocomplete="current-password"
              value={@current_password}
              placeholder="••••••••"
              $input={:update_current_password} />

            <label class="field-label" style="margin-top: 14px;">new password</label>
            <input
              class="app-input"
              type="password"
              name="new_password"
              autocomplete="new-password"
              value={@new_password}
              placeholder="at least 8 characters"
              $input={:update_new_password} />

            <label class="field-label" style="margin-top: 14px;">confirm new password</label>
            <input
              class="app-input"
              type="password"
              name="new_password_confirmation"
              autocomplete="new-password"
              value={@new_password_confirmation}
              placeholder="repeat new password"
              $input={:update_new_password_confirmation} />

            {%if @password_error}
              <div class="form-error">{@password_error}</div>
            {/if}
            {%if @password_message}
              <div class="form-success">{@password_message}</div>
            {/if}

            <div style="margin-top: 20px; display: flex; gap: 8px; justify-content: flex-end;">
              <button type="submit" class="app-btn app-btn-primary">change password</button>
            </div>
          </form>
        </section>

        <section class="surface profile-card profile-card-wide">
          <div class="section-header" style="border-bottom: 1px solid var(--hairline); padding-bottom: 12px; margin-bottom: 18px;">
            <h2>recovery code</h2>
            <span class="mono" style="font-size: 11px; color: var(--muted);">
              {%if @recovery_status == :active}set up{%else}{%if @recovery_status == :guest}guest{%else}not set up{/if}{/if}
            </span>
          </div>

          {%if @recovery_status == :guest}
            <p class="sub" style="font-size: 13px; margin: 0;">
              register to get a recovery code. it lets you set a new password if you forget yours.
            </p>
          {%else}
            {%if @recovery_status == :active}
              <p class="sub" style="font-size: 13px; margin: 0 0 14px;">
                your recovery code was generated <span class="mono">{@recovery_generated_label}</span>.
                it can only set a new password. lost it? generate a new one and the old code stops working.
              </p>
            {%else}
              <p class="sub" style="font-size: 13px; margin: 0 0 14px;">
                set up a recovery code: it is the only way to reset a forgotten password,
                since scrawly sends no email.
              </p>
            {/if}

            <form $submit={:regenerate_recovery_code}>
              <label class="field-label">current password</label>
              <div class="row" style="gap: 8px; align-items: stretch; flex-wrap: wrap;">
                <input
                  class="app-input"
                  style="flex: 1; min-width: 200px;"
                  type="password"
                  name="recovery_current_password"
                  autocomplete="current-password"
                  value={@recovery_password}
                  placeholder="••••••••"
                  $input={:update_recovery_password} />
                <button type="submit" class="app-btn app-btn-primary">
                  {%if @recovery_status == :active}generate a new code{%else}set up a recovery code{/if}
                </button>
              </div>

              {%if @recovery_error}
                <div class="form-error">{@recovery_error}</div>
              {/if}
              {%if @recovery_message}
                <div class="form-success">{@recovery_message}</div>
              {/if}
            </form>
          {/if}
        </section>
      </div>

      {%if @recovery_code}
        <RecoveryCodePanel code={@recovery_code} saved={@recovery_code_saved} />
      {/if}
    </div>
    """
  end

  # ── Profile form actions ─────────────────────────────────────────────

  def action(:update_username, %{event: %{value: val}}, component) do
    put_state(component, :username, val)
  end

  def action(:pick_avatar, %{id: id}, component) do
    put_state(component, :avatar_id, id)
  end

  def action(:pick_color, %{color: color}, component) do
    put_state(component, :avatar_color, color)
  end

  def action(:save_profile, _params, component) do
    component
    |> put_state(:profile_error, nil)
    |> put_state(:profile_message, nil)
    |> put_command(:save_profile, %{
      username: component.state.username,
      avatar_id: component.state.avatar_id,
      avatar_color: component.state.avatar_color
    })
  end

  def action(:profile_saved, params, component) do
    component
    |> put_state(:profile_message, params.message)
    |> put_state(:profile_error, nil)
    |> put_state(:username, params.username)
    |> put_state(:avatar_id, params.avatar_id)
    |> put_state(:avatar_color, params.avatar_color)
    |> put_action(
      name: :profile_updated,
      target: "layout",
      params: %{
        username: params.username,
        avatar_id: params.avatar_id,
        avatar_color: params.avatar_color
      }
    )
  end

  def action(:profile_failed, %{message: message}, component) do
    component
    |> put_state(:profile_error, message)
    |> put_state(:profile_message, nil)
  end

  # ── Password form actions ───────────────────────────────────────────

  def action(:update_current_password, %{event: %{value: val}}, component) do
    put_state(component, :current_password, val)
  end

  def action(:update_new_password, %{event: %{value: val}}, component) do
    put_state(component, :new_password, val)
  end

  def action(:update_new_password_confirmation, %{event: %{value: val}}, component) do
    put_state(component, :new_password_confirmation, val)
  end

  def action(:save_password, _params, component) do
    component
    |> put_state(:password_error, nil)
    |> put_state(:password_message, nil)
    |> put_command(:save_password, %{
      current_password: component.state.current_password,
      password: component.state.new_password,
      password_confirmation: component.state.new_password_confirmation
    })
  end

  def action(:password_saved, %{message: message}, component) do
    component
    |> put_state(:password_message, message)
    |> put_state(:password_error, nil)
    |> put_state(:current_password, "")
    |> put_state(:new_password, "")
    |> put_state(:new_password_confirmation, "")
  end

  def action(:password_failed, %{message: message}, component) do
    component
    |> put_state(:password_error, message)
    |> put_state(:password_message, nil)
  end

  # ── Recovery code actions ───────────────────────────────────────────

  def action(:update_recovery_password, %{event: %{value: val}}, component) do
    put_state(component, :recovery_password, val)
  end

  def action(:regenerate_recovery_code, _params, component) do
    component
    |> put_state(:recovery_error, nil)
    |> put_state(:recovery_message, nil)
    |> put_command(:regenerate_recovery_code, %{
      current_password: component.state.recovery_password
    })
  end

  def action(:recovery_code_failed, %{message: message}, component) do
    component
    |> put_state(:recovery_error, message)
    |> put_state(:recovery_message, nil)
  end

  def action(:show_recovery_code, %{code: code} = params, component) do
    component
    |> put_state(:recovery_password, "")
    |> put_state(:recovery_status, :active)
    |> put_state(:recovery_generated_label, Map.get(params, :generated_label, ""))
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
    |> put_state(:recovery_message, "recovery code saved. any older code no longer works.")
  end

  # ── Commands ────────────────────────────────────────────────────────

  def command(:regenerate_recovery_code, params, server) do
    ScrawlyWeb.Recovery.regenerate(params, server)
  end

  def command(:save_profile, params, server) do
    user_id = get_session(server, :user_id)

    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id),
         {:ok, updated} <-
           Scrawly.Accounts.update_profile(user, %{
             username: params.username,
             avatar_id: params.avatar_id,
             avatar_color: params.avatar_color
           }) do
      put_action(server, :profile_saved,
        message: "profile updated.",
        username: updated.username,
        avatar_id: updated.avatar_id,
        avatar_color: updated.avatar_color
      )
    else
      {:error, %Ash.Error.Invalid{errors: errors}} ->
        put_action(server, :profile_failed, message: format_errors(errors))

      _ ->
        put_action(server, :profile_failed, message: "could not update profile.")
    end
  end

  def command(:save_password, params, server) do
    user_id = get_session(server, :user_id)

    with {:ok, user} <- Ash.get(Scrawly.Accounts.User, user_id),
         {:ok, _updated} <-
           Scrawly.Accounts.change_password(user, %{
             current_password: params.current_password,
             password: params.password,
             password_confirmation: params.password_confirmation
           }) do
      put_action(server, :password_saved, message: "password changed.")
    else
      {:error, %Ash.Error.Invalid{errors: errors}} ->
        put_action(server, :password_failed, message: format_errors(errors))

      _ ->
        put_action(server, :password_failed, message: "could not change password.")
    end
  end

  defp format_errors(errors) do
    errors
    |> Enum.map(fn err ->
      cond do
        is_exception(err) -> Exception.message(err)
        is_binary(err) -> err
        true -> inspect(err)
      end
    end)
    |> Enum.join(" · ")
  end
end
