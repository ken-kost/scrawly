defmodule ScrawlyWeb.GameSocketJsTest do
  @moduledoc """
  priv/static/game_socket.js (`window.gameSocket`) exposes only what the game
  page's JS uses, and pushes only events GameChannel handles: the live stroke
  chunks stayed on the channel after the measured Realtime gate
  (REALTIME_MIGRATION_REPORT.md), everything else moved to Hologram, so the
  old senders without a channel handler are gone.
  """
  use ExUnit.Case, async: true

  @socket_js "priv/static/game_socket.js"
  @channel "lib/scrawly_web/channels/game_channel.ex"

  @dead_senders ~w(sendDrawingSegment sendDrawingStroke sendDrawingStrokeComplete
                   sendDrawingClear sendDrawingUndo requestDrawingPath
                   onDrawingSegment onDrawingClear)

  defp methods(source) do
    ~r/^\s{4}(\w+): function/m
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  test "every event game_socket.js pushes has a GameChannel handler" do
    pushed =
      ~r/channel\.push\("([^"]+)"/
      |> Regex.scan(File.read!(@socket_js), capture: :all_but_first)
      |> List.flatten()

    assert pushed == ["drawing_stroke_chunk"]

    channel = File.read!(@channel)
    for event <- pushed, do: assert(channel =~ ~s|def handle_in("#{event}"|, event)
  end

  test "the dead senders are gone" do
    sources =
      [@socket_js | Path.wildcard("lib/**/*.{ex,mjs,js}") ++ Path.wildcard("assets/js/**/*.js")]
      |> Enum.map(&{&1, File.read!(&1)})

    for name <- @dead_senders, {path, source} <- sources do
      refute source =~ ~r/\b#{name}\b/, "#{path} still mentions #{name}"
    end

    refute File.exists?("assets/js/user_socket.js")
  end

  test "game_socket.js exposes exactly the methods the page JS calls" do
    called =
      Path.wildcard("lib/scrawly_web/pages/*.mjs")
      |> Enum.flat_map(fn path ->
        ~r/\b(?:gs|gameSocket)\.(\w+)/
        |> Regex.scan(File.read!(path), capture: :all_but_first)
        |> List.flatten()
      end)
      |> Enum.uniq()
      |> Enum.sort()

    exposed = @socket_js |> File.read!() |> methods() |> Enum.sort()

    # leaveRoom is used by disconnect/joinRoom inside game_socket.js itself.
    assert exposed -- ["leaveRoom"] == called
  end
end
