defmodule Propagator.Datalog do
  @moduledoc """
  Serialize a propagator network's belief state as Datalog facts.

  Each cell becomes a `.dl` file with its beliefs as Datalog atoms.
  Each rule becomes a `.dl` file describing its input/output wiring.
  A `schema.dl` file captures the cell metadata.

  ## File layout

      cells/
        temperature.dl      # belief(75, sensor_reading, in).
        humidity.dl          # belief(60, sensor_reading, in).
      rules/
        ac_rule.dl           # input(temperature). output(cooling_on).
      schema.dl              # cell(temperature, sensor, "Room temperature", "°F").

  ## Why Datalog

  Datalog gives you a logic-programming view of the network state:
  facts you can query, diff, and trace through git history. Each commit
  is a state transition. `git log -- cells/temperature.dl` shows how
  a sensor's beliefs evolved over time. `git diff HEAD~1` shows exactly
  what changed in the last transition.
  """

  @doc """
  Serialize a domain's current state to a map of `path => content`.

  Accepts a domain struct implementing `ValueInterface` and the network
  snapshot from `Network.inspect_state/1`. Returns a map like:

      %{
        "schema.dl" => "cell(temperature, sensor, ...).\n...",
        "cells/temperature.dl" => "belief(75, sensor_reading, in).\n...",
        "rules/ac_rule.dl" => "input(temperature).\noutput(cooling_on).\n"
      }
  """
  def serialize(domain, snapshot) do
    cell_specs = domain.__struct__.cell_specs()
    rule_specs = domain.__struct__.rule_specs()
    cell_ids = domain.__struct__.cell_ids(domain)

    # Invert: cell_id => cell_name (available for future query support)
    _id_to_name = Map.new(cell_ids, fn {name, id} -> {id, name} end)

    files = %{}

    # Schema file
    files = Map.put(files, "schema.dl", serialize_schema(cell_specs))

    # Cell files
    files =
      Enum.reduce(cell_specs, files, fn spec, acc ->
        cell_id = cell_ids[spec.name]
        cell_view = snapshot.cells[cell_id]
        content = serialize_cell(spec, cell_view)
        Map.put(acc, "cells/#{spec.name}.dl", content)
      end)

    # Rule files
    files =
      Enum.reduce(rule_specs, files, fn spec, acc ->
        content = serialize_rule(spec)
        Map.put(acc, "rules/#{spec.name}.dl", content)
      end)

    files
  end

  @doc """
  Parse a cell `.dl` file back into structured data.

  Returns a map with `:name`, `:type`, `:description`, `:unit`,
  `:active_value`, and `:beliefs` (list of `{value, informant, status}` tuples).
  """
  def parse_cell(text) do
    lines = String.split(text, "\n")
    meta = parse_metadata(lines)
    beliefs = parse_beliefs(lines)

    %{
      name: parse_atom(meta["cell"]),
      type: parse_atom(meta["type"]),
      description: meta["description"],
      unit: meta["unit"],
      active_value: parse_value(meta["active_value"]),
      beliefs: beliefs
    }
  end

  @doc """
  Parse a rule `.dl` file back into structured data.

  Returns a map with `:name`, `:description`, `:inputs`, and `:outputs`.
  """
  def parse_rule(text) do
    lines = String.split(text, "\n")
    meta = parse_metadata(lines)

    inputs =
      lines
      |> Enum.filter(&String.starts_with?(&1, "input("))
      |> Enum.map(&parse_single_arg_fact/1)

    outputs =
      lines
      |> Enum.filter(&String.starts_with?(&1, "output("))
      |> Enum.map(&parse_single_arg_fact/1)

    %{
      name: parse_atom(meta["rule"]),
      description: meta["description"],
      inputs: inputs,
      outputs: outputs
    }
  end

  @doc """
  Parse the `schema.dl` file back into a list of cell specs.
  """
  def parse_schema(text) do
    text
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "cell("))
    |> Enum.map(&parse_cell_fact/1)
  end

  # --- Serialization helpers ---

  defp serialize_schema(cell_specs) do
    header = "%% Network schema\n%% Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n\n"

    facts =
      cell_specs
      |> Enum.map(fn spec ->
        unit = if spec.unit, do: inspect(spec.unit), else: "nil"
        "cell(#{spec.name}, #{spec.type}, #{inspect(spec.description)}, #{unit})."
      end)
      |> Enum.join("\n")

    header <> facts <> "\n"
  end

  defp serialize_cell(spec, cell_view) do
    active_value = format_value(cell_view.active_value)

    header =
      "%% cell: #{spec.name}\n" <>
        "%% type: #{spec.type}\n" <>
        "%% description: #{spec.description}\n" <>
        "%% unit: #{spec.unit || "none"}\n" <>
        "%% active_value: #{active_value}\n\n"

    beliefs =
      cell_view.beliefs
      |> Enum.sort_by(fn b -> {!b.active, "#{b.informant}"} end)
      |> Enum.map(fn b ->
        status = if b.active, do: "in", else: "out"
        "belief(#{format_value(b.value)}, #{b.informant}, #{status})."
      end)
      |> Enum.join("\n")

    if beliefs == "" do
      header
    else
      header <> beliefs <> "\n"
    end
  end

  defp serialize_rule(spec) do
    header =
      "%% rule: #{spec.name}\n" <>
        "%% description: #{spec.description}\n\n"

    inputs = Enum.map(spec.inputs, &"input(#{&1}).") |> Enum.join("\n")
    outputs = Enum.map(spec.outputs, &"output(#{&1}).") |> Enum.join("\n")

    header <> inputs <> "\n" <> outputs <> "\n"
  end

  # --- Parsing helpers ---

  defp parse_metadata(lines) do
    lines
    |> Enum.filter(&String.starts_with?(&1, "%% "))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim_leading(line, "%% "), ": ", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp parse_beliefs(lines) do
    lines
    |> Enum.filter(&String.starts_with?(&1, "belief("))
    |> Enum.map(&parse_belief_fact/1)
  end

  # Parse: belief(75, sensor_reading, in).
  defp parse_belief_fact(line) do
    inner = extract_parens(line)
    parts = split_args(inner)

    case parts do
      [value_str, informant_str, status_str] ->
        {parse_value(value_str), parse_atom(informant_str), parse_atom(status_str)}

      _ ->
        nil
    end
  end

  # Parse: cell(temperature, sensor, "Room temperature", "°F").
  defp parse_cell_fact(line) do
    inner = extract_parens(line)
    parts = split_args(inner)

    case parts do
      [name, type, desc, unit] ->
        %{
          name: parse_atom(name),
          type: parse_atom(type),
          description: parse_string(desc),
          unit: parse_unit(unit)
        }

      _ ->
        nil
    end
  end

  # Parse: input(temperature).
  defp parse_single_arg_fact(line) do
    inner = extract_parens(line)
    parse_atom(String.trim(inner))
  end

  # Extract content between parens: "belief(75, foo, in)." -> "75, foo, in"
  defp extract_parens(line) do
    line
    |> String.trim()
    |> String.trim_trailing(".")
    |> then(fn s ->
      case String.split(s, "(", parts: 2) do
        [_, rest] -> String.trim_trailing(rest, ")")
        _ -> ""
      end
    end)
  end

  # Split "75, sensor_reading, in" respecting quoted strings
  defp split_args(str) do
    str
    |> do_split_args([], "", false)
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp do_split_args("", acc, current, _in_quote) do
    [current | acc]
  end

  defp do_split_args(<<"\\", char, rest::binary>>, acc, current, in_quote) do
    do_split_args(rest, acc, current <> <<char>>, in_quote)
  end

  defp do_split_args(<<?", rest::binary>>, acc, current, in_quote) do
    do_split_args(rest, acc, current <> "\"", !in_quote)
  end

  defp do_split_args(<<?,, rest::binary>>, acc, current, false) do
    do_split_args(rest, [current | acc], "", false)
  end

  defp do_split_args(<<char, rest::binary>>, acc, current, in_quote) do
    do_split_args(rest, acc, current <> <<char>>, in_quote)
  end

  # --- Value formatting/parsing ---

  defp format_value(:nothing), do: "nothing"
  defp format_value(:contradiction), do: "contradiction"
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(v) when is_float(v), do: Float.to_string(v)
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(v), do: inspect(v)

  defp parse_value("nothing"), do: :nothing
  defp parse_value("contradiction"), do: :contradiction
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false
  defp parse_value("nil"), do: nil

  defp parse_value(str) do
    str = String.trim(str)

    cond do
      String.contains?(str, ".") ->
        case Float.parse(str) do
          {f, ""} -> f
          _ -> str
        end

      true ->
        case Integer.parse(str) do
          {i, ""} -> i
          _ -> str
        end
    end
  end

  defp parse_atom(nil), do: nil

  defp parse_atom(str) do
    str |> String.trim() |> String.to_atom()
  end

  defp parse_string(str) do
    str
    |> String.trim()
    |> String.trim("\"")
  end

  defp parse_unit("nil"), do: nil
  defp parse_unit(str), do: parse_string(str)
end
