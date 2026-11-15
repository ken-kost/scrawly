defmodule ScrawlyWeb.ClientIp do
  @moduledoc """
  The client's IP address, for per-client limits (`Scrawly.Accounts.Throttle`).

  Behind a reverse proxy every request arrives from the proxy, so a per-IP
  limit would become one global limit (one attacker could lock everybody
  out). `config :scrawly, ScrawlyWeb.ClientIp, header: "fly-client-ip"` (set
  for prod in config/runtime.exs) names a request header the proxy sets to the
  real client address. Configure only a header the proxy always overwrites:
  clients can send any header. Without a header (dev, test), or when it holds
  no valid address, the peer address is used.
  """

  alias Hologram.Server

  @doc "The client IP of a Hologram request (middleware, `init/3`, `command/3`)."
  @spec from_server(Server.t()) :: String.t() | nil
  def from_server(%Server{} = server) do
    header_ip(Map.get(server.request_headers || %{}, header())) || server.ip
  end

  @doc "The client IP of a Phoenix request."
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{} = conn) do
    header_value = conn |> Plug.Conn.get_req_header(header() || "") |> List.first()
    header_ip(header_value) || peer_ip(conn.remote_ip)
  end

  defp header, do: :scrawly |> Application.get_env(__MODULE__, []) |> Keyword.get(:header)

  # The first address of the header, normalised; nil when absent or invalid.
  defp header_ip(value) when is_binary(value) do
    candidate = value |> String.split(",") |> List.first() |> String.trim()

    case :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, address} -> peer_ip(address)
      {:error, _} -> nil
    end
  end

  defp header_ip(_value), do: nil

  defp peer_ip(nil), do: nil
  defp peer_ip(address), do: address |> :inet.ntoa() |> to_string()
end
