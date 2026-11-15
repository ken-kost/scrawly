defmodule ScrawlyWeb.EndpointLimitsTest do
  @moduledoc """
  QA G2, transport side: how much a client may send in one request or one
  WebSocket frame.

    * The game/demo socket refuses frames over 32 KiB (the biggest legitimate
      one is a demo stroke of at most 8,000 path bytes in a ~150-byte
      envelope), and Bandit refuses fragmented WebSocket messages over 64 KiB
      on every socket (Phoenix can't set that per socket).
    * Plug.Parsers reads at most 128 KiB of a request body, so a Hologram
      command (JSON, strings hex-encoded: a 8,000-byte stroke path is ~16 KB)
      fits with room to spare, while a megabyte body is refused with 413
      before anything decodes it.
  """
  use ScrawlyWeb.ConnCase, async: true

  test "the /socket websocket has a max_frame_size" do
    {_path, _socket, opts} =
      Enum.find(ScrawlyWeb.Endpoint.__sockets__(), &match?({"/socket", _, _}, &1))

    assert opts[:websocket][:max_frame_size] == 32_768
  end

  test "Bandit caps every WebSocket's frames and fragmented messages" do
    ws = Application.fetch_env!(:scrawly, ScrawlyWeb.Endpoint)[:http][:websocket_options]

    assert ws[:max_frame_size] == 65_536
    assert ws[:max_fragmented_message_size] == 65_536
  end

  test "a request body over 128 KiB is refused with 413", %{conn: conn} do
    body = Jason.encode!([1, %{"padding" => String.duplicate("a", 200_000)}])

    assert_error_sent 413, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/hologram/command", body)
    end
  end

  test "a command the size of the largest stroke commit is read", %{conn: conn} do
    # An 8,000-byte path, hex-encoded the way the Hologram client sends
    # strings, plus room for the rest of the envelope.
    body = Jason.encode!([1, %{"path" => String.duplicate("ab", 8_000 * 2)}])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/hologram/command", body)

    # Read and handed on (no CSRF token, so Hologram turns it away).
    assert conn.status in [403, 404]
  end
end
