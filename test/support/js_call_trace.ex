defmodule Scrawly.JsCallTrace do
  @moduledoc """
  Sees which JavaScript functions a Hologram action calls when it runs on the
  server in a test: `Hologram.JS.call/4` is a no-op there, so `js_calls/1`
  traces it.
  """

  @doc """
  Runs `fun` and returns `{result, [{js_function, args}]}` for every
  `Hologram.JS.call` it made, in order. A trace session keeps the pattern
  private to the calling test; a collector process receives the trace
  messages. Use from `async: false` tests.
  """
  def js_calls(fun) do
    Code.ensure_loaded!(Hologram.JS)
    collector = spawn_link(fn -> collect_js_calls([]) end)
    session = :trace.session_create(:js_call_trace, collector, [])

    try do
      1 = :trace.function(session, {Hologram.JS, :call, 4}, true, [:global])
      1 = :trace.process(session, self(), true, [:call])
      result = fun.()

      ref = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _pid, ^ref} -> :ok
      end

      send(collector, {:calls, self()})

      receive do
        {:js_calls, calls} -> {result, calls}
      end
    after
      :trace.session_destroy(session)
    end
  end

  @doc """
  Runs `fun` and returns `{result, [code]}` for every inline script it ran
  (`~JS"..."` or `Hologram.JS.exec/1`), in order. Same tracing as
  `js_calls/1`.
  """
  def js_execs(fun) do
    Code.ensure_loaded!(Hologram.JS)
    collector = spawn_link(fn -> collect_js_execs([]) end)
    session = :trace.session_create(:js_exec_trace, collector, [])

    try do
      1 = :trace.function(session, {Hologram.JS, :exec, 1}, true, [:global])
      1 = :trace.function(session, {Hologram.JS, :sigil_JS, 2}, true, [:global])
      1 = :trace.process(session, self(), true, [:call])
      result = fun.()

      ref = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _pid, ^ref} -> :ok
      end

      send(collector, {:execs, self()})

      receive do
        {:js_execs, execs} -> {result, execs}
      end
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_js_execs(acc) do
    receive do
      {:trace, _pid, :call, {Hologram.JS, :exec, [code]}} ->
        collect_js_execs([code | acc])

      {:trace, _pid, :call, {Hologram.JS, :sigil_JS, [code, _mods]}} ->
        collect_js_execs([code | acc])

      {:execs, from} ->
        send(from, {:js_execs, Enum.reverse(acc)})
    end
  end

  @doc "The names of the JS functions `fun` called, in order."
  def js_call_names(fun) do
    {result, calls} = js_calls(fun)
    {result, Enum.map(calls, &elem(&1, 0))}
  end

  defp collect_js_calls(acc) do
    receive do
      {:trace, _pid, :call, {Hologram.JS, :call, [_receiver, name, args, _module]}} ->
        collect_js_calls([{name, args} | acc])

      {:calls, from} ->
        send(from, {:js_calls, Enum.reverse(acc)})
    end
  end
end
