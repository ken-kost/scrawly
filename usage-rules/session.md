# Session

## Core Concept

- Session provides secure server-side storage that persists across page visits within a browsing session.
- Session data is stored in a secure session cookie — it is opaque to client-side code.
- Session is accessible only through the `%Server{}` struct: in `init/3` and in commands.

## Functions

- `get_session(server, key)` — read a value (returns `nil` if missing).
- `get_session(server, key, default)` — read with a default fallback.
- `put_session(server, key, value)` — write a value.
- `delete_session(server, key)` — remove a value.
- Session keys must be atoms or strings.

## Do

- Use session for sensitive data: user IDs, roles, authentication tokens, CSRF tokens.
- Always provide defaults when reading session data that might not exist: `get_session(server, :cart, [])`.
- Clean up session data on logout with `delete_session/2`.
- Use session in `init/3` for reading auth state and initializing component state from it.
- Use session in commands for dynamic session management (login, cart operations, etc.).
- Chain session operations with the pipe operator: `server |> put_session(:a, 1) |> put_session(:b, 2)`.

## Don't

- Don't try to access session from actions — session is only available via `%Server{}` (in `init/3` and commands).
- Don't use non-atom, non-string keys — they will cause errors.
- Don't store large amounts of data in session — keep it minimal for performance.
- Don't confuse session with direct cookie management. Session data is automatically secured and opaque to the client. Use direct cookies when you need client-side JS access or specific cookie behavior.
