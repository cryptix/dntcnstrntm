defmodule Propagator.UI.Json do
  @moduledoc """
  Minimal JSON encoder — no external dependencies.

  Supports: nil, booleans, integers, floats, binaries, atoms, lists, maps.
  Map keys are converted to strings.  Atom values are converted to strings.

  This is intentionally narrow — just enough to serialise Network snapshots.
  """

  @doc "Encode `value` to a JSON binary. Raises on unsupported types."
  def encode!(value) do
    value |> encode() |> IO.iodata_to_binary()
  end

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"

  defp encode(n) when is_integer(n), do: Integer.to_string(n)

  defp encode(n) when is_float(n) do
    # Use Erlang's float_to_binary for compact representation
    :erlang.float_to_binary(n, [:compact, {:decimals, 6}])
  end

  defp encode(s) when is_binary(s) do
    [?", escape(s), ?"]
  end

  defp encode(a) when is_atom(a), do: encode(Atom.to_string(a))

  defp encode(list) when is_list(list) do
    ["[", Enum.map(list, &encode/1) |> Enum.intersperse(","), "]"]
  end

  defp encode(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} ->
        [encode(to_string(k)), ":", encode(v)]
      end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  @doc "Decode a simple flat JSON object (no nesting required for POST bodies)."
  def decode_object!(s) when is_binary(s) do
    s
    |> String.trim()
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> split_pairs()
    |> Map.new(fn {k, v} -> {k, parse_value(v)} end)
  end

  defp split_pairs(s) do
    # Very simple tokeniser for flat {"k":"v","k":n} — good enough for our POST bodies
    Regex.scan(~r/"([^"]+)"\s*:\s*("(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|true|false|null)/, s)
    |> Enum.map(fn [_, k, v] -> {k, v} end)
  end

  defp parse_value("null"), do: nil
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(v) when is_binary(v) do
    if String.starts_with?(v, "\"") do
      v |> String.slice(1..-2//1) |> unescape()
    else
      case Integer.parse(v) do
        {i, ""} -> i
        _ ->
          case Float.parse(v) do
            {f, ""} -> f
            _ -> v
          end
      end
    end
  end

  defp unescape(s) do
    s
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
  end
end
