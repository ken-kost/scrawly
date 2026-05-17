# Forms

## Two Approaches

- **Synchronized inputs**: state is kept in sync via `$change` on individual inputs + `value={@state_var}`. Unidirectional data flow — component state is the single source of truth.
- **Non-synchronized inputs**: no input-level `$change`. Read values from form-level `$change` or `$submit` handlers via `params.event`.

## Do

- For synchronized text inputs and selects, use `value={@var}` plus `$change="handler"`.
- For synchronized checkboxes and radios, use `checked={@var}` or `checked={@var == "value"}` plus `$change="handler"`.
- For synchronized inputs, read the new value from `params.event.value` in the input-level `$change` action.
- For non-synchronized inputs, use form-level `$change` or `$submit` — `params.event` contains a map of all field names to their current values.
- Use `$submit` on `<form>` for form submission. The event data contains all fields as a map: `%{email: "...", password: "..."}`.
- Use `name` attributes on all inputs — they become keys in `params.event` for form-level events and `$submit`.
- Leverage isomorphic validation: the same Elixir validation code (including Ecto changesets) runs both client-side and server-side.
- Use form-level `$change` for validate-on-blur workflows (it fires on native `change`, typically on focus loss).
- Use commands for actual form submission/persistence when server-side processing is needed.

## Don't

- Don't confuse `$change` behavior: on text inputs it maps to native `input` (fires every keystroke); on checkboxes/radios/selects it maps to native `change`.
- Don't mix up input-level vs form-level `$change` semantics: input-level gives `params.event.value` (single value); form-level gives `params.event` as a map of all fields.
- Don't use `<textarea>` with children for content — use `value={@content}` attribute instead (like React).
- Don't forget that checkbox values come as booleans and radio/select values come as strings.
- Don't skip server-side validation — client-side validation improves UX but server-side ensures security and data integrity.
