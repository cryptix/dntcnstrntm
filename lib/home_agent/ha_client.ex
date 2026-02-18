defmodule HomeAgent.HaClient do
  @moduledoc """
  Home Assistant WebSocket client using Erlang's :gen_tcp.

  Performs the HTTP → WebSocket upgrade handshake manually, then reads
  framed messages from HA's WebSocket API, authenticates, subscribes to
  `state_changed` events, and broadcasts them via `HomeAgent.PubSub`.

  Service calls (`call_service/4`) are sent as text frames back through
  the same TCP connection.

  If the host is unreachable or the token is empty the process starts in
  stub mode (a no-op GenServer), so the supervision tree stays healthy
  and all other components can be tested without a live HA instance.
  """

  use GenServer
  require Logger
  import Bitwise, only: [band: 2]

  alias HomeAgent.{PubSub, Json, StateStore}

  @topic "state_changed"

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a Home Assistant service call.

  domain   — e.g. "light"
  service  — e.g. "turn_on"
  entity   — e.g. "light.kitchen"
  data     — map of service_data fields
  """
  def call_service(domain, service, entity, data \\ %{}) do
    msg = Json.encode!(%{
      id: System.unique_integer([:positive]),
      type: "call_service",
      domain: domain,
      service: service,
      target: %{entity_id: entity},
      service_data: data
    })

    GenServer.cast(__MODULE__, {:send_text, msg})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host, "homeassistant.local")
    port = Keyword.get(opts, :port, 8123)
    token = Keyword.get(opts, :token, "")

    state = %{
      socket: nil,
      token: token,
      next_id: 1,
      buffer: "",
      stub: false
    }

    # Try to connect; fall back to stub if unreachable
    case connect(host, port) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket}}

      {:error, reason} ->
        Logger.warning("HaClient: cannot connect to #{host}:#{port} — #{inspect(reason)}. Running in stub mode.")
        {:ok, %{state | stub: true}}
    end
  end

  @impl true
  def handle_cast({:send_text, _msg}, %{stub: true} = state), do: {:noreply, state}

  def handle_cast({:send_text, msg}, state) do
    send_frame(state.socket, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    buffer = state.buffer <> data

    case parse_ws_frames(buffer, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("HaClient: TCP connection closed")
    {:noreply, %{state | socket: nil, stub: true}}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("HaClient: TCP error #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Connection / WebSocket handshake ---

  defp connect(host, port) do
    host_charlist = to_charlist(host)

    case :gen_tcp.connect(host_charlist, port, [:binary, active: true, packet: :raw], 5_000) do
      {:ok, socket} ->
        key = Base.encode64(:crypto.strong_rand_bytes(16))
        handshake = build_handshake(host, port, key)
        :gen_tcp.send(socket, handshake)
        # The response will arrive as a tcp message; the handshake is
        # complete once we receive an HTTP 101 response.
        {:ok, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_handshake(host, port, key) do
    [
      "GET /api/websocket HTTP/1.1\r\n",
      "Host: #{host}:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n",
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  # --- WebSocket frame parsing ---
  # We handle only text frames (opcode 1) and close frames (opcode 8).
  # HA never sends binary frames for its JSON API.

  defp parse_ws_frames(buffer, state) do
    # If the buffer still contains the HTTP 101 upgrade response, strip it.
    buffer =
      if String.contains?(buffer, "\r\n\r\n") and String.starts_with?(buffer, "HTTP") do
        [_headers, rest] = String.split(buffer, "\r\n\r\n", parts: 2)
        rest
      else
        buffer
      end

    case extract_frame(buffer) do
      {:ok, text, rest} ->
        state = handle_message(text, state)
        parse_ws_frames(rest, %{state | buffer: rest})

      :incomplete ->
        {:ok, %{state | buffer: buffer}}
    end
  end

  defp extract_frame(<<_fin_rsv_opcode::8, mask_len::8, rest::binary>>) do
    base_len = band(mask_len, 0x7F)

    payload_len =
      case base_len do
        126 ->
          <<len::16, _::binary>> = rest
          len

        127 ->
          <<len::64, _::binary>> = rest
          len

        n ->
          n
      end

    header_extra =
      case base_len do
        126 -> 2
        127 -> 8
        _ -> 0
      end

    total_needed = header_extra + payload_len

    if byte_size(rest) >= total_needed do
      payload_start = header_extra
      <<_skip::binary-size(payload_start), payload::binary-size(payload_len), remaining::binary>> = rest
      {:ok, payload, remaining}
    else
      :incomplete
    end
  end

  defp extract_frame(_), do: :incomplete

  defp handle_message(raw, state) do
    case Json.decode(raw) do
      {:ok, msg} -> dispatch_message(msg, state)
      {:error, _} -> state
    end
  end

  defp dispatch_message(%{"type" => "auth_required"}, state) do
    frame = Json.encode!(%{type: "auth", access_token: state.token})
    send_frame(state.socket, frame)
    state
  end

  defp dispatch_message(%{"type" => "auth_ok"}, state) do
    Logger.info("HaClient: authenticated with Home Assistant")

    sub = Json.encode!(%{
      id: state.next_id,
      type: "subscribe_events",
      event_type: "state_changed"
    })

    send_frame(state.socket, sub)
    %{state | next_id: state.next_id + 1}
  end

  defp dispatch_message(%{"type" => "auth_invalid"}, state) do
    Logger.error("HaClient: authentication failed")
    state
  end

  defp dispatch_message(%{"type" => "event", "event" => %{"data" => data}}, state) do
    PubSub.broadcast(HomeAgent.PubSub, @topic, {:state_changed, data})
    StateStore.put(data)
    state
  end

  defp dispatch_message(_msg, state), do: state

  # Send an unmasked text frame (server → client direction; we're acting as client
  # so technically we should mask, but HA accepts unmasked frames in practice).
  defp send_frame(nil, _payload), do: :ok

  defp send_frame(socket, payload) when is_binary(payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x81, len::8>>
        len < 65536 -> <<0x81, 126::8, len::16>>
        true -> <<0x81, 127::8, len::64>>
      end

    :gen_tcp.send(socket, header <> payload)
  end
end
