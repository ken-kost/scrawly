defmodule Scrawly.MobApp do
  @moduledoc """
  On-device BEAM entry — thin client for the deployed Scrawly server.

  Does NOT start `:scrawly` as an OTP application: the host's
  `Scrawly.Application` brings up Phoenix + Hologram + Ash + game
  servers, all of which belong on the deployed fly.io node, not on
  the phone. This module is invoked from `src/scrawly.erl` (the
  Erlang bootstrap called by Mob's native shell).
  """

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Scrawly.MobScreen)
  end

  @impl Mob.App
  def on_start do
    Mob.DNS.configure_pure_beam()

    Mob.Screen.start_root(Scrawly.MobScreen)

    Mob.Dist.ensure_started(
      node: :"scrawly_android@127.0.0.1",
      cookie: :mob_secret
    )
  end
end
