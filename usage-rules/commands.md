# Commands

## Core Concept

- Commands are **server-side** operations that run on the server asynchronously.
- They access databases, files, external APIs, manage session/cookies, and trigger client-side actions.
- Defined as: `def command(name, params, server) do ... end`
- Must return a `%Server{}` struct.

## Do

- Use `put_action/2` or `put_action/3` to trigger a client-side action after server work completes.
- Use `put_session/3` to write session data: `put_session(server, :user_id, user.id)`.
- Use `put_cookie/3` to set browser cookies.
- Chain operations with the pipe operator: `server |> put_session(:user_id, id) |> put_action(:logged_in)`.
- Use commands for all privileged operations: authentication, data persistence, API calls, file access.
- Trigger commands from actions with `put_command/2` or `put_command/3`, or from templates with longhand event syntax.
- Access event data via `params.event` and custom params directly from `params`.

## Don't

- Don't update component state directly in commands — commands return `%Server{}`, not `%Component{}`. Use `put_action` to send data back to the client where an action can update state.
- Don't use `put_state` in commands — it doesn't exist on `%Server{}`.
- Don't call `put_page` from commands (not yet supported — use `put_action` to trigger client-side navigation).
- Don't use `delay:` with commands — delays are only supported for actions.
- Don't forget that commands are async — the UI won't block waiting for them. Set a loading state in the action before triggering the command.
