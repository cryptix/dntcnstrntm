defmodule Propagator.UI.Router do
  @moduledoc """
  HTTP request dispatcher — no external dependencies.

  Called by `HttpServer` with parsed method/path/query/headers/body.
  Returns a complete HTTP/1.1 response binary (headers + body).

  Routes:
    GET  /              — Single-page HTML inspector
    GET  /api/state     — Full network snapshot (JSON)
    GET  /api/events    — Events since ?since=N (JSON)
    GET  /api/meta      — Domain cell + rule specs (JSON)
    POST /api/assert    — Assert a belief (JSON body)
    POST /api/retract   — Retract beliefs (JSON body)
  """

  alias Propagator.UI.RoomServer
  alias Propagator.UI.Html
  alias Propagator.UI.Json

  # ── Dispatch ──────────────────────────────────────────────────────────────

  def handle("GET", "/", _query, _headers, _body) do
    html_resp(200, Html.page())
  end

  def handle("GET", "/api/state", _query, _headers, _body) do
    snapshot = RoomServer.inspect_state()
    json_resp(200, serialize_snapshot(snapshot))
  end

  def handle("GET", "/api/events", query, _headers, _body) do
    since =
      case Map.get(query, "since") do
        nil -> 0
        s -> String.to_integer(s)
      end

    events = RoomServer.get_events(since)
    json_resp(200, %{"events" => Enum.map(events, &serialize_event/1)})
  end

  def handle("GET", "/api/meta", _query, _headers, _body) do
    meta = RoomServer.domain_meta()
    json_resp(200, serialize_meta(meta))
  end

  def handle("POST", "/api/assert", _query, _headers, body) do
    with {:ok, params} <- parse_body(body),
         {:ok, cell_name} <- fetch_atom(params, "cell"),
         {:ok, raw} <- Map.fetch(params, "value"),
         {:ok, source} <- fetch_atom(params, "source"),
         {:ok, value} <- coerce_value(raw) do
      case RoomServer.set(cell_name, value, source) do
        :ok -> json_resp(200, %{"ok" => true})
        {:error, r} -> json_resp(422, %{"ok" => false, "error" => inspect(r)})
      end
    else
      _ -> json_resp(400, %{"ok" => false, "error" => "missing or invalid field"})
    end
  end

  def handle("POST", "/api/retract", _query, _headers, body) do
    with {:ok, params} <- parse_body(body),
         {:ok, cell_name} <- fetch_atom(params, "cell"),
         {:ok, source} <- fetch_atom(params, "source") do
      case RoomServer.retract(cell_name, source) do
        :ok -> json_resp(200, %{"ok" => true})
        {:error, r} -> json_resp(422, %{"ok" => false, "error" => inspect(r)})
      end
    else
      _ -> json_resp(400, %{"ok" => false, "error" => "missing field: cell, source"})
    end
  end

  def handle(_method, _path, _query, _headers, _body) do
    text_resp(404, "not found")
  end

  # ── Serialisation ─────────────────────────────────────────────────────────

  defp serialize_snapshot(%{cells: cells, propagators: props, events: events} = snap) do
    %{
      "cells" =>
        Map.new(cells, fn {id, c} -> {to_string(id), serialize_cell(c)} end),
      "propagators" =>
        Map.new(props, fn {id, p} -> {to_string(id), serialize_propagator(p)} end),
      "events" => Enum.map(events, &serialize_event/1),
      "cell_name_to_id" =>
        Map.new(snap[:cell_name_to_id] || %{}, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp serialize_cell(c) do
    %{
      "id" => c.id,
      "name" => to_string(c[:name] || "cell_#{c.id}"),
      "type" => to_string(c[:type] || "unknown"),
      "description" => c[:description] || "",
      "unit" => c[:unit],
      "active_value" => serialize_value(c.active_value),
      "status" => to_string(c.status),
      "beliefs" => Enum.map(c.beliefs, &serialize_belief/1)
    }
  end

  defp serialize_belief(b) do
    %{
      "value" => serialize_value(b.value),
      "informant" => to_string(b.informant),
      "active" => b.active
    }
  end

  defp serialize_propagator(p) do
    %{
      "id" => p.id,
      "rule_name" => to_string(p[:rule_name] || p.informant),
      "description" => p[:description] || "",
      "inputs" => p.inputs,
      "outputs" => p.outputs
    }
  end

  defp serialize_event(e) do
    e
    |> Map.new(fn {k, v} -> {to_string(k), serialize_event_val(k, v)} end)
  end

  defp serialize_event_val(:type, v), do: to_string(v)
  defp serialize_event_val(:informant, v), do: to_string(v)
  defp serialize_event_val(:cell_name, v), do: to_string(v)
  defp serialize_event_val(:old_value, v), do: serialize_value(v)
  defp serialize_event_val(:new_value, v), do: serialize_value(v)
  defp serialize_event_val(:value, v), do: serialize_value(v)
  defp serialize_event_val(_, v) when is_atom(v), do: to_string(v)
  defp serialize_event_val(_, v), do: v

  defp serialize_meta(meta) do
    %{
      "domain" => meta.domain,
      "cell_specs" =>
        Enum.map(meta.cell_specs, fn s ->
          %{
            "name" => to_string(s.name),
            "type" => to_string(s.type),
            "description" => s.description,
            "unit" => s.unit
          }
        end),
      "rule_specs" =>
        Enum.map(meta.rule_specs, fn s ->
          %{
            "name" => to_string(s.name),
            "description" => s.description,
            "inputs" => Enum.map(s.inputs, &to_string/1),
            "outputs" => Enum.map(s.outputs, &to_string/1)
          }
        end)
    }
  end

  defp serialize_value(:nothing), do: nil
  defp serialize_value(:contradiction), do: "contradiction"
  defp serialize_value(v) when is_float(v), do: Float.round(v, 3)
  defp serialize_value(v), do: v

  # ── HTTP response builders ────────────────────────────────────────────────

  defp json_resp(status, body_map) do
    json = Json.encode!(body_map)
    build_resp(status, "application/json", json)
  end

  defp html_resp(status, html) do
    build_resp(status, "text/html; charset=utf-8", html)
  end

  defp text_resp(status, text) do
    build_resp(status, "text/plain", text)
  end

  defp build_resp(status, content_type, body) do
    status_line = "HTTP/1.1 #{status} #{status_text(status)}\r\n"
    len = byte_size(body)

    headers =
      "Content-Type: #{content_type}\r\n" <>
        "Content-Length: #{len}\r\n" <>
        "Access-Control-Allow-Origin: *\r\n" <>
        "Connection: close\r\n" <>
        "\r\n"

    status_line <> headers <> body
  end

  defp status_text(200), do: "OK"
  defp status_text(400), do: "Bad Request"
  defp status_text(404), do: "Not Found"
  defp status_text(422), do: "Unprocessable Entity"
  defp status_text(_), do: "Error"

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp parse_body(""), do: {:ok, %{}}
  defp parse_body(nil), do: {:ok, %{}}

  defp parse_body(body) do
    try do
      {:ok, Json.decode_object!(body)}
    rescue
      _ -> :error
    end
  end

  defp fetch_atom(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when is_binary(v) ->
        try do
          {:ok, String.to_existing_atom(v)}
        rescue
          ArgumentError -> :error
        end

      {:ok, v} when is_atom(v) ->
        {:ok, v}

      _ ->
        :error
    end
  end

  defp coerce_value(v) when is_number(v), do: {:ok, v}
  defp coerce_value(v) when is_boolean(v), do: {:ok, v}

  defp coerce_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ ->
        case Integer.parse(v) do
          {i, ""} -> {:ok, i}
          _ -> {:ok, v}
        end
    end
  end

  defp coerce_value(_), do: :error
end
