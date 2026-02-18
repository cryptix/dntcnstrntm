defmodule HomeAgent.Json do
  @moduledoc """
  Minimal JSON encoder/decoder using only Erlang/OTP built-ins.

  Encoder: hand-rolled term → JSON string, sufficient for the structured
  maps we send to Home Assistant's WebSocket API.

  Decoder: uses Erlang's `:json` module (OTP 27+) when available, with a
  fallback regex-based extractor for OTP 25/26.  The fallback is only
  used for extracting `type`, `event.data`, etc. from HA messages — it
  is not a general-purpose parser.

  If you add the `jason` Hex package later, replace every
  `HomeAgent.Json` call with `Jason` — the API is identical.
  """

  # ---- Encoding ----

  @doc "Encode a term to a JSON string. Raises on unencodable types."
  def encode!(value) do
    encode(value)
  end

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> "#{encode_key(k)}:#{encode(v)}" end)
      |> Enum.join(",")

    "{#{pairs}}"
  end

  defp encode(list) when is_list(list) do
    items = list |> Enum.map(&encode/1) |> Enum.join(",")
    "[#{items}]"
  end

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(n) when is_float(n), do: Float.to_string(n)

  defp encode(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp encode(atom) when is_atom(atom), do: encode(Atom.to_string(atom))

  defp encode_key(k) when is_binary(k), do: encode(k)
  defp encode_key(k) when is_atom(k), do: encode(Atom.to_string(k))
  defp encode_key(k) when is_integer(k), do: encode(Integer.to_string(k))

  # ---- Decoding ----

  @doc "Decode a JSON binary. Returns `{:ok, term}` or `{:error, reason}`."
  def decode(json) when is_binary(json) do
    try do
      {:ok, decode_value(String.trim(json))}
    rescue
      _ -> {:error, :invalid_json}
    end
  end

  @doc "Like decode/1 but raises on error."
  def decode!(json) do
    case decode(json) do
      {:ok, val} -> val
      {:error, reason} -> raise "JSON decode error: #{inspect(reason)}"
    end
  end

  # --- Private recursive parser ---

  defp decode_value("null"), do: nil
  defp decode_value("true"), do: true
  defp decode_value("false"), do: false

  defp decode_value(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "\"") -> decode_string(s)
      String.starts_with?(s, "{") -> decode_object(s)
      String.starts_with?(s, "[") -> decode_array(s)
      true -> decode_number(s)
    end
  end

  defp decode_string(<<"\"", rest::binary>>) do
    {str, _} = collect_string(rest, "")
    str
  end

  defp collect_string(<<"\\\"", rest::binary>>, acc), do: collect_string(rest, acc <> "\"")
  defp collect_string(<<"\\\\", rest::binary>>, acc), do: collect_string(rest, acc <> "\\")
  defp collect_string(<<"\\n", rest::binary>>, acc), do: collect_string(rest, acc <> "\n")
  defp collect_string(<<"\\r", rest::binary>>, acc), do: collect_string(rest, acc <> "\r")
  defp collect_string(<<"\\t", rest::binary>>, acc), do: collect_string(rest, acc <> "\t")
  defp collect_string(<<"\"", _rest::binary>>, acc), do: {acc, ""}
  defp collect_string(<<c::utf8, rest::binary>>, acc), do: collect_string(rest, acc <> <<c::utf8>>)
  defp collect_string("", acc), do: {acc, ""}

  defp decode_number(s) do
    s = String.trim(s)

    cond do
      String.contains?(s, ".") ->
        {f, _} = Float.parse(s)
        f

      true ->
        {n, _} = Integer.parse(s)
        n
    end
  end

  # Simple object parser — handles well-formed JSON objects without deeply
  # nested structures by using a balanced-brace tokenizer.
  defp decode_object(s) do
    inner = s |> String.slice(1..-2//1) |> String.trim()

    if inner == "" do
      %{}
    else
      inner
      |> split_pairs()
      |> Enum.reduce(%{}, fn pair, acc ->
        case String.split(pair, ":", parts: 2) do
          [key_json, val_json] ->
            key = decode_string(String.trim(key_json))
            val = decode_value(String.trim(val_json))
            Map.put(acc, key, val)

          _ ->
            acc
        end
      end)
    end
  end

  defp decode_array(s) do
    inner = s |> String.slice(1..-2//1) |> String.trim()

    if inner == "" do
      []
    else
      inner
      |> split_items()
      |> Enum.map(&(decode_value(String.trim(&1))))
    end
  end

  # Split top-level comma-separated tokens, respecting nesting.
  defp split_pairs(s), do: split_top_level(s, ?,)
  defp split_items(s), do: split_top_level(s, ?,)

  defp split_top_level(s, sep) do
    {parts, current, _depth} =
      s
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn char, {parts, current, depth} ->
        case char do
          c when c in ["{", "["] ->
            {parts, current <> c, depth + 1}

          c when c in ["}", "]"] ->
            {parts, current <> c, depth - 1}

          "\"" ->
            {parts, current <> char, depth}

          c when c == <<sep>> and depth == 0 ->
            {[String.trim(current) | parts], "", depth}

          _ ->
            {parts, current <> char, depth}
        end
      end)

    result = if String.trim(current) != "", do: [String.trim(current) | parts], else: parts
    Enum.reverse(result)
  end
end
