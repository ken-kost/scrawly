defmodule ScrawlyWeb.Pages.ProfilePage do
  use Hologram.Page

  route "/profile"
  layout ScrawlyWeb.Layouts.AppLayout

  alias ScrawlyWeb.Components.{Avatar, AvatarDefs}

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
      </div>
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

  # ── Commands ────────────────────────────────────────────────────────

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
