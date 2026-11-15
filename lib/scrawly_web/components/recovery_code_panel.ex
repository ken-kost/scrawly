defmodule ScrawlyWeb.Components.RecoveryCodePanel do
  @moduledoc """
  Shows a freshly issued recovery code once, with copy / download buttons and
  an "I have saved it" checkbox that unlocks Continue.

  Stateless: its events go to the nearest stateful ancestor, so every owner
  (HomePage, AppLayout, ProfilePage) implements the same actions:

    * `:copy_recovery_code` and `:download_recovery_code` (JS.call into
      `recovery_code.mjs`, which each owner imports itself); the copy also
      sets the owner's `copied` flag, which the copy button shows;
    * `:set_recovery_code_saved` (`%{event: %{value: boolean}}`);
    * `:close_recovery_code`, which must drop the plaintext from state.
  """

  use Hologram.Component

  prop :code, :string, required: true
  prop :saved, :boolean, default: false
  # The code was copied (the button says so until the panel closes).
  prop :copied, :boolean, default: false

  def template do
    ~HOLO"""
    <div class="scrim">
      <div class="app-modal" style="max-width: 440px;">
        <div class="app-modal-head">
          <div>
            <h3>save your recovery code</h3>
            <div class="sub">it is the only way to reset a forgotten password. we show it once.</div>
          </div>
        </div>
        <div class="app-modal-body">
          <div class="recovery-code mono" data-testid="recovery-code">{@code}</div>
          <div class="row" style="gap: 8px;">
            <button type="button" class="app-btn app-btn-sm" $click={:copy_recovery_code}>{if(@copied, do: "copied ✓", else: "copy")}</button>
            <button type="button" class="app-btn app-btn-sm" $click={:download_recovery_code}>download .txt</button>
          </div>
          <div style="font-size: 12px; color: var(--muted); line-height: 1.5;">
            use it with "forgot password?" to set a new password. it works once:
            you get a new code each time you use it.
          </div>
          <label class="row" style="gap: 8px; font-size: 13px; cursor: pointer;">
            <input type="checkbox" name="recovery_code_saved" checked={@saved} $change={:set_recovery_code_saved} />
            I have saved it somewhere safe
          </label>
        </div>
        <div class="app-modal-foot">
          <button type="button" class="app-btn app-btn-primary" disabled={!@saved} $click={:close_recovery_code}>continue</button>
        </div>
      </div>
    </div>
    """
  end

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
