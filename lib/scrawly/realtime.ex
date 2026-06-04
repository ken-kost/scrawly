defmodule Scrawly.Realtime do
  @moduledoc """
  Thin wrapper around `Hologram.Realtime` for producers that live outside
  Hologram handlers — chiefly `Scrawly.Games.RoomServer`, which broadcasts
  chat/state deltas to subscribed game pages from its mutation choke points.

  Hologram's realtime layer (including its `Hologram.PubSub`) only runs when the
  Hologram runtime is started: production, or dev/test with `HOLOGRAM_START=1`
  (i.e. `mix holo`). When it is not started, calling
  `Hologram.Realtime.broadcast_action/3` would raise because `Hologram.PubSub`
  is absent. These wrappers no-op in that case, so producers can broadcast
  unconditionally and the test suite (which runs with Hologram disabled) and a
  plain `mix phx.server` stay safe.

  Run the dev server with `mix holo` to exercise the realtime path locally.
  """

  # Hologram's compiler hides framework modules from cross-module static
  # analysis, so the standard Elixir compiler can't see `Hologram.Realtime`
  # here even though it is present at runtime (it ships in the :hologram dep and
  # broadcasting from plain processes is its documented use). Suppress the
  # spurious "module not available" warning; runtime availability is real.
  @compile {:no_warn_undefined, Hologram.Realtime}

  @doc """
  Broadcasts `action_name` (with `params`) to every page subscribed to `channel`.
  No-op when the Hologram runtime is not started.
  """
  @spec broadcast_action(atom | tuple, atom, keyword | map) :: :ok
  def broadcast_action(channel, action_name, params \\ %{}) do
    if Hologram.enabled?() do
      Hologram.Realtime.broadcast_action(channel, action_name, params)
    else
      :ok
    end
  end

  @doc """
  Like `broadcast_action/3` but excludes one or more identities (`{:instance, id}`,
  `{:session, id}`, `{:user, id}`) from delivery. No-op when the Hologram runtime
  is not started.
  """
  @spec broadcast_action_except(tuple | [tuple], atom | tuple, atom, keyword | map) :: :ok
  def broadcast_action_except(except, channel, action_name, params \\ %{}) do
    if Hologram.enabled?() do
      Hologram.Realtime.broadcast_action_except(except, channel, action_name, params)
    else
      :ok
    end
  end
end
