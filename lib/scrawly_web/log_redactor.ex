defmodule ScrawlyWeb.LogRedactor do
  @moduledoc """
  A primary `:logger` filter that keeps credentials out of crash logs.

  When a request crashes, Bandit logs `Exception.format/3` of the error. Its
  stacktrace prints the arguments of the frame that raised (a
  FunctionClauseError, or an UndefinedFunctionError for a forged Hologram
  command naming a module without `command/3`), and for Hologram commands one
  argument is the `%Hologram.Server{}`: the raw cookies (the signed session
  cookie), the CSRF token and the session's sign-in JWT. Other arguments can be
  typed passwords. The `crash_reason` metadata carries the same stacktrace for
  any handler that formats it later.

  For every event with a `crash_reason` that carries any of that, this
  filter:

    * replaces each frame's arguments with their arity (module, function and
      line stay, which is what locates the bug);
    * scrubs the exception's own fields (e.g. `KeyError.term`) of
      `%Hologram.Server{}`, `%Plug.Conn{}` and values under password/token keys;
    * rebuilds the message when it is an `Exception.format/3` text (it starts
      with `"** ("`, as Bandit's does).

  If redaction itself fails, the event is still logged, without its report.
  `install/0` runs at application start.
  """

  @filter_id :scrawly_redact_crash_args

  @sensitive_keys ~w(password password_confirmation current_password new_password
                     new_password_confirmation recovery_code code token user_token
                     socket_token _csrf_token)

  @doc "Adds the filter (replacing an earlier copy) to the primary logger config."
  @spec install() :: :ok | {:error, term}
  def install do
    _ = :logger.remove_primary_filter(@filter_id)
    :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []})
  end

  @doc false
  def filter(%{meta: %{crash_reason: {reason, stacktrace}}} = event, _extra)
      when is_list(stacktrace) do
    clean_stacktrace = Enum.map(stacktrace, &strip_args/1)
    clean_reason = scrub_reason(reason)

    if clean_stacktrace == stacktrace and clean_reason == reason do
      event
    else
      meta = %{event.meta | crash_reason: {clean_reason, clean_stacktrace}}
      %{event | meta: meta, msg: redacted_msg(event.msg, clean_reason, clean_stacktrace)}
    end
  rescue
    _ ->
      %{
        event
        | msg: {:string, "crash report dropped: it could not be redacted"},
          meta: Map.delete(event.meta, :crash_reason)
      }
  end

  def filter(event, _extra), do: event

  defp strip_args({mod, fun, args, loc}) when is_list(args), do: {mod, fun, length(args), loc}
  defp strip_args(frame), do: frame

  defp redacted_msg({:string, text} = msg, reason, stacktrace) do
    if String.starts_with?(IO.chardata_to_string(text), "** (") do
      {:string, format(reason, stacktrace)}
    else
      msg
    end
  end

  defp redacted_msg(msg, _reason, _stacktrace), do: msg

  defp format({:nocatch, value}, stacktrace), do: Exception.format(:throw, value, stacktrace)

  defp format(reason, stacktrace) do
    if is_exception(reason),
      do: Exception.format(:error, reason, stacktrace),
      else: Exception.format(:exit, reason, stacktrace)
  end

  defp scrub_reason({:nocatch, value}), do: {:nocatch, scrub(value)}

  defp scrub_reason(%FunctionClauseError{} = error), do: %{error | args: nil}

  defp scrub_reason(%{__exception__: true} = error) do
    error
    |> Map.from_struct()
    |> Map.new(fn
      {key, value} when key in [:__exception__, :message] -> {key, value}
      {key, value} -> {key, scrub(value)}
    end)
    |> then(&struct(error.__struct__, &1))
  end

  defp scrub_reason(reason), do: scrub(reason)

  @doc false
  # Replaces credential carriers anywhere inside `term`.
  def scrub(%Hologram.Server{}), do: :"[redacted Hologram.Server]"
  def scrub(%Plug.Conn{}), do: :"[redacted Plug.Conn]"
  def scrub(%_{} = struct), do: struct

  def scrub(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[redacted]"}, else: {key, scrub(value)}
    end)
  end

  def scrub(list) when is_list(list) do
    if List.improper?(list), do: list, else: Enum.map(list, &scrub/1)
  end

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  def scrub(other), do: other

  defp sensitive_key?(key) when is_atom(key), do: Atom.to_string(key) in @sensitive_keys
  defp sensitive_key?(key) when is_binary(key), do: key in @sensitive_keys
  defp sensitive_key?(_key), do: false
end
