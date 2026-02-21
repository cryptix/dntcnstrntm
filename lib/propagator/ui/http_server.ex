defmodule Propagator.UI.HttpServer do
  @moduledoc """
  Zero-dependency HTTP/1.1 server using Erlang's `:gen_tcp`.

  Listens on `@port` (default 4000). For each incoming connection:
    1. Parses the HTTP request line and headers using Erlang's built-in
       `:gen_tcp` HTTP packet mode.
    2. Reads the body if `Content-Length` is present.
    3. Dispatches to `Propagator.UI.Router.handle/4`.
    4. Sends the HTTP response and closes the socket.

  Each connection is handled in its own spawned process so the accept loop
  is never blocked.
  """

  use GenServer
  require Logger

  @port 4000

  # ── Public API ───────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], Keyword.put_new(opts, :name, __MODULE__))
  end

  def port, do: @port

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_) do
    case :gen_tcp.listen(@port, [
           :binary,
           packet: :http_bin,
           active: false,
           reuseaddr: true,
           backlog: 128
         ]) do
      {:ok, listen_socket} ->
        Logger.info("Propagator Inspector: http://localhost:#{@port}")
        # Start accepting in a separate linked process
        acceptor = spawn_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{listen_socket: listen_socket, acceptor: acceptor}}

      {:error, reason} ->
        Logger.error("Failed to start HTTP server on port #{@port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{listen_socket: s}) do
    :gen_tcp.close(s)
  end

  # ── Accept loop (runs in a dedicated process) ────────────────────────────

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        spawn(fn -> handle_connection(client) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  # ── Connection handler ────────────────────────────────────────────────────

  defp handle_connection(socket) do
    with {:ok, method, path, query} <- read_request_line(socket),
         {:ok, headers} <- read_headers(socket),
         {:ok, body} <- read_body(socket, headers) do
      response = Propagator.UI.Router.handle(method, path, query, headers, body)
      :gen_tcp.send(socket, response)
    else
      _ -> :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request_line(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_request, method_atom, http_uri, _version}} ->
        method = Atom.to_string(method_atom)
        {path, query} = decode_uri(http_uri)
        {:ok, method, path, query}

      {:ok, {:http_error, line}} ->
        Logger.debug("HTTP parse error on: #{inspect(line)}")
        :error

      {:error, _} = err ->
        err
    end
  end

  defp decode_uri({:abs_path, path_with_query}) do
    case String.split(path_with_query, "?", parts: 2) do
      [path, query] -> {path, URI.decode_query(query)}
      [path] -> {path, %{}}
    end
  end

  defp decode_uri({:absoluteURI, _scheme, _host, _port, path_with_query}) do
    decode_uri({:abs_path, path_with_query})
  end

  defp decode_uri(_), do: {"/", %{}}

  defp read_headers(socket) do
    read_headers(socket, [])
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_header, _, name, _, value}} ->
        key = header_key(name)
        read_headers(socket, [{key, value} | acc])

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:error, _} = err ->
        err
    end
  end

  defp header_key(name) when is_atom(name), do: Atom.to_string(name) |> String.downcase()
  defp header_key(name) when is_binary(name), do: String.downcase(name)

  defp read_body(socket, headers) do
    case Enum.find(headers, fn {k, _} -> k == "content-length" end) do
      {_, len_str} ->
        len = String.to_integer(len_str)

        if len > 0 do
          :inet.setopts(socket, packet: :raw)
          :gen_tcp.recv(socket, len, 5000)
        else
          {:ok, ""}
        end

      nil ->
        {:ok, ""}
    end
  end
end
