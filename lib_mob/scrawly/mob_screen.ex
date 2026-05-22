defmodule Scrawly.MobScreen do
  @moduledoc """
  Mob.Screen that wraps the host Phoenix app in a native WebView.

  Reads `MOB_HOST_URL` at runtime so the same module works pointing
  at the deployed Scrawly server (the default) or a local Phoenix
  during development (`MOB_HOST_URL=http://10.0.0.5:4123/` for an
  emulator hitting your dev machine's IP, etc.).
  """
  use Mob.Screen

  @device_id_filename "device_id"

  def host_url do
    base = System.get_env("MOB_HOST_URL", "https://scrawly.fly.dev/")

    case device_id() do
      nil -> base
      uuid -> append_query(base, "device_id", uuid)
    end
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(_assigns) do
    Mob.UI.webview(
      url: host_url(),
      show_url: false
    )
  end

  # Returns a stable per-device UUID stored in the app's persistent
  # storage. Generates one on first call. Returns `nil` on host (where
  # `:mob_nif` is unavailable), so dev/test builds skip the auto-login
  # query param and behave like a regular browser.
  defp device_id do
    try do
      path = Path.join(Mob.Storage.dir(:app_support), @device_id_filename)

      case File.read(path) do
        {:ok, contents} ->
          String.trim(contents)

        _ ->
          uuid = Ecto.UUID.generate()
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, uuid)
          uuid
      end
    rescue
      _ -> nil
    end
  end

  defp append_query(url, key, value) do
    uri = URI.parse(url)
    existing = URI.decode_query(uri.query || "")
    new_query = existing |> Map.put(key, value) |> URI.encode_query()

    %{uri | query: new_query}
    |> URI.to_string()
  end
end
