# Hologram's realtime runtime is disabled in the test env, so its PubSub isn't
# started. RoomServer/commands broadcast deltas through Hologram.Realtime
# (which publishes on Hologram.PubSub), so start just that PubSub here to let
# those broadcasts no-op to zero subscribers instead of raising.
unless Process.whereis(Hologram.PubSub) do
  {:ok, _} =
    Supervisor.start_link([{Phoenix.PubSub, name: Hologram.PubSub}],
      strategy: :one_for_one,
      name: Scrawly.Test.HologramPubSubSupervisor
    )
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Scrawly.Repo, :manual)
