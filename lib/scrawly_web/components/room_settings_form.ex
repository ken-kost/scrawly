defmodule ScrawlyWeb.Components.RoomSettingsForm do
  @moduledoc """
  A room's settings as a form, in a modal: name, answers, topic (with your
  own theme and its style), draw time, turns each and players. Home uses it
  to create a room; the lobby uses it to change one (its host only).

  The form owns the values while it is open; the parent owns what happens
  with them:

      <div class="scrim">
        <RoomSettingsForm cid="create-room-1"
                          on_submit={:create_room} on_cancel={:hide_create_room}
                          busy={@creating_room?} errors={@create_room_errors} />
      </div>

  Props:

    * `cid` - required (the form is stateful). Hologram keeps a cid's state
      after the form is hidden, so a parent that wants `initial` again on the
      next opening gives that opening a new cid.
    * `initial` - the values to start from, keyed like
      `ScrawlyWeb.RoomSettings.defaults/0`, as strings, atoms or integers (a
      room's own fields work as they are). Missing keys take the defaults.
    * `on_submit` - the parent's action, run with `%{values: values}` (every
      value a string, keyed like `defaults/0`) when the form is submitted and
      valid. The parent sends its command and sets `busy` until the reply.
    * `on_cancel` - the parent's action for cancel, the close button and
      Escape.
    * `parent_cid` - where both actions go (default `"page"`).
    * `busy` - the parent's command is running: the submit button shows
      `busy_label` and is disabled, and submitting does nothing.
    * `min_players` - the players already in the room (the lobby's form):
      "players" offers no limit below it and says why. Default 2, every
      option.
    * `errors` - the server's answer, `%{field => message}`: a field key
      (`:name`, `:prompt`, `:max_players`) puts the message under that field,
      `:form` on the line above the buttons. The values stay as they were.
    * `title`, `subtitle`, `submit_label`, `busy_label`, `name_placeholder` -
      wording.

  Focus starts in the name field, Enter submits (the browser's implicit
  submission: nothing happens while the submit button is disabled), Escape
  cancels. The form stops "n" so Home's N shortcut doesn't fire while typing.
  """
  use Hologram.Component
  use Hologram.JS

  js_import :focusField, from: "./focus_field.mjs"

  alias ScrawlyWeb.RoomSettings

  prop :initial, :map, default: %{}
  prop :on_submit, :atom, required: true
  prop :on_cancel, :atom, required: true
  prop :parent_cid, :string, default: "page"
  prop :busy, :boolean, default: false
  prop :min_players, :integer, default: 2
  prop :errors, :map, default: %{}
  prop :title, :string, default: "new room"
  prop :subtitle, :string, default: "ready to play as it is. change what you like."
  prop :submit_label, :string, default: "create room"
  prop :busy_label, :string, default: "creating…"
  prop :name_placeholder, :string, default: "e.g. late night doodles"

  def init(props, component) do
    component
    |> put_state(:values, RoomSettings.form_values(Map.get(props, :initial)))
    |> put_action(:focus_name)
  end

  def init(props, component, _server), do: init(props, component)

  def template do
    ~HOLO"""
    <form class="app-modal app-modal-pinned" $submit="submit" $key_down.n.stop_propagation="noop">
      <window $key_down.escape={action: @on_cancel, target: @parent_cid} />
      <div class="app-modal-head">
        <div>
          <h3>{@title}</h3>
          <div class="sub">{@subtitle}</div>
        </div>
        <button type="button" class="icon-btn" aria-label="close" $click={action: @on_cancel, target: @parent_cid}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" width="18" height="18"><path d="M6 6l12 12M18 6L6 18" stroke-linecap="round"/></svg>
        </button>
      </div>
      <div class="app-modal-body">
        <div>
          <label class="field-label" for={@cid <> "-name"}>name</label>
          <input class="app-input" id={@cid <> "-name"} name="name" autocomplete="off"
                 maxlength={RoomSettings.name_max()} placeholder={@name_placeholder}
                 value={@values.name} $change={:put_value, field: :name} />
          {%if Map.get(@errors, :name)}
            <div class="field-error">{Map.get(@errors, :name)}</div>
          {/if}
        </div>

        <div>
          <div class="field-label">answers</div>
          <div class="seg">
            {%for {value, label} <- RoomSettings.answer_options()}
              <button type="button" class={if(@values.answer_kind == value, do: "active", else: "")}
                      aria-pressed={if(@values.answer_kind == value, do: "true", else: "false")}
                      $click={:put_value, field: :answer_kind, value: value}>{label}</button>
            {/for}
          </div>
          <div class="field-hint">e.g. {RoomSettings.example(@values.answer_kind)}</div>
        </div>

        <div>
          <div class="field-label">topic</div>
          <div class="seg">
            {%for {value, label} <- RoomSettings.topic_options()}
              <button type="button" class={if(@values.word_source == value, do: "active", else: "")}
                      aria-pressed={if(@values.word_source == value, do: "true", else: "false")}
                      $click={:put_value, field: :word_source, value: value}>{label}</button>
            {/for}
          </div>
          {%if @values.word_source == "ai"}
            <input class="app-input" id={@cid <> "-theme"} name="prompt" autocomplete="off"
                   style="margin-top: 8px;" aria-label="your theme"
                   maxlength={RoomSettings.theme_max()} placeholder="ocean animals, things in a kitchen…"
                   value={@values.prompt} $change={:put_value, field: :prompt} />
            {%if Map.get(@errors, :prompt)}
              <div class="field-error">{Map.get(@errors, :prompt)}</div>
            {%else}
              {%if RoomSettings.missing_theme?(@values)}
                <div class="field-hint">type a theme to create the room, or pick everything.</div>
              {%else}
                <div class="field-hint">AI picks the words for your theme when the game starts.</div>
              {/if}
            {/if}
            <div class="field-label" style="margin-top: 14px;">style</div>
            <div class="seg">
              {%for {value, label} <- RoomSettings.style_options()}
                <button type="button" class={if(@values.ai_tone == value, do: "active", else: "")}
                        aria-pressed={if(@values.ai_tone == value, do: "true", else: "false")}
                        $click={:put_value, field: :ai_tone, value: value}>{label}</button>
              {/for}
            </div>
          {/if}
        </div>

        <div class="field-pair">
          <div>
            <div class="field-label">draw time</div>
            <div class="seg">
              {%for {value, label} <- RoomSettings.draw_time_options()}
                <button type="button" class={if(@values.round_duration == value, do: "active", else: "")}
                        aria-pressed={if(@values.round_duration == value, do: "true", else: "false")}
                        $click={:put_value, field: :round_duration, value: value}>{label}</button>
              {/for}
            </div>
          </div>
          <div>
            <div class="field-label">turns each</div>
            <div class="seg">
              {%for {value, label} <- RoomSettings.turn_options()}
                <button type="button" class={if(@values.round_multiplier == value, do: "active", else: "")}
                        aria-pressed={if(@values.round_multiplier == value, do: "true", else: "false")}
                        $click={:put_value, field: :round_multiplier, value: value}>{label}</button>
              {/for}
            </div>
            <div class="field-hint">{RoomSettings.turns_hint(@values.round_multiplier)}</div>
          </div>
        </div>

        <div>
          <label class="field-label" for={@cid <> "-players"}>players</label>
          <select class="app-input" id={@cid <> "-players"} name="max_players"
                  value={@values.max_players} $change={:put_value, field: :max_players}>
            {%for {value, label} <- RoomSettings.player_options()}
              <option value={value} disabled={RoomSettings.too_few_players?(value, @min_players)}>{label}</option>
            {/for}
          </select>
          {%if Map.get(@errors, :max_players)}
            <div class="field-error">{Map.get(@errors, :max_players)}</div>
          {%else}
            {%if @min_players > 2}
              <div class="field-hint">{RoomSettings.players_floor(@min_players)}</div>
            {/if}
          {/if}
        </div>
      </div>
      {%if Map.get(@errors, :form)}
        <div class="app-modal-error" role="alert">{Map.get(@errors, :form)}</div>
      {/if}
      <div class="app-modal-foot">
        <button type="button" class="app-btn app-btn-ghost" $click={action: @on_cancel, target: @parent_cid}>cancel</button>
        <button type="submit" class="app-btn app-btn-primary"
                disabled={@busy or RoomSettings.missing_theme?(@values)}>
          {%if @busy}{@busy_label}{%else}{@submit_label}{/if}
        </button>
      </div>
    </form>
    """
  end

  # A seg button (`value`) or a field's change event (`event.value`). Picking
  # your own theme moves the focus to the theme field.
  def action(:put_value, %{field: field, event: %{value: value}}, component),
    do: put_value(component, field, value)

  def action(:put_value, %{field: field, value: value}, component),
    do: put_value(component, field, value)

  # Only valid values reach the parent; while its command runs (`busy`) a
  # second submit does nothing.
  def action(:submit, _params, component) do
    values = component.state.values

    if component.props.busy or RoomSettings.missing_theme?(values) do
      component
    else
      put_action(component,
        name: component.props.on_submit,
        target: component.props.parent_cid,
        params: %{values: values}
      )
    end
  end

  def action(:focus_name, _params, component) do
    JS.call(:focusField, [component.props.cid <> "-name"])
    component
  end

  # The form's typing guard (see the moduledoc).
  def action(:noop, _params, component), do: component

  defp put_value(component, field, value) when is_binary(value) do
    if RoomSettings.field?(field) do
      if field == :word_source and value == "ai" and component.state.values.word_source != "ai",
        do: JS.call(:focusField, [component.props.cid <> "-theme"])

      put_state(component, [:values, field], value)
    else
      component
    end
  end

  defp put_value(component, _field, _value), do: component

  # No commands here. A forged one (the module is named in the request) is
  # denied instead of raising (see ScrawlyWeb.CommandParams).
  def command(name, _params, server), do: ScrawlyWeb.CommandParams.deny_unknown(server, name)
end
