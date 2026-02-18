defmodule HomeAgent.Datalog.RuleEngine do
  @moduledoc """
  Evaluates Datalog programs using the Soufflé CLI (interpreted mode).

  The engine concatenates a static rules file (`priv/rules.dl` and
  `priv/beliefs.dl`) with a freshly generated facts file, invokes
  `souffle -D- <program.dl>`, and parses the tab-separated CSV output
  back into a structured map of relation name → list of tuples.

  If Soufflé is not installed the engine returns `{:error, :souffle_not_found}`
  and logs a warning — the fast-path propagator network continues operating.

  ## Soufflé output format

  With `-D-`, Soufflé prints each output relation preceded by a header line:
      ---------------
      should_light_on
      ---------------
      kitchen\t2700\t153

  We split on the `---------------` separator, then parse each block.
  """

  require Logger

  @rules_path "priv/rules.dl"
  @beliefs_path "priv/beliefs.dl"

  @doc """
  Evaluate the combined program (rules + beliefs + facts) and return
  `{:ok, results}` where results is a map of relation name → [[field, …], …],
  or `{:error, reason}`.
  """
  def evaluate(facts_path) do
    with {:ok, rules} <- read_static_file(@rules_path),
         {:ok, beliefs} <- read_static_file(@beliefs_path),
         {:ok, facts} <- File.read(facts_path) do
      run_souffle(rules <> "\n" <> beliefs <> "\n" <> facts)
    end
  end

  @doc """
  Like `evaluate/1` but accepts a raw facts string instead of a file path.
  Useful for testing.
  """
  def evaluate_string(facts_string) do
    with {:ok, rules} <- read_static_file(@rules_path),
         {:ok, beliefs} <- read_static_file(@beliefs_path) do
      run_souffle(rules <> "\n" <> beliefs <> "\n" <> facts_string)
    end
  end

  @doc """
  Parse Soufflé `-D-` output into `%{relation_name => [[field, …], …]}`.
  Public so it can be unit-tested independently.
  """
  def parse_output(output) do
    # Soufflé -D- output format:
    #   ---------------\nrelation_name\n---------------\nrow1\nrow2\n...
    # Splitting on the separator yields:
    #   ["", "\nrelation_name\n", "\nrow1\nrow2\n", "\nrelation2\n", ...]
    # We drop the leading empty string, then chunk in pairs [name, rows].
    output
    |> String.split(~r/^-+$/m)
    |> Enum.drop(1)
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case chunk do
        [name_block, rows_block] ->
          relation = String.trim(name_block)

          rows =
            rows_block
            |> String.split("\n", trim: true)
            |> Enum.map(&String.split(&1, "\t"))
            |> Enum.reject(&(&1 == [""]))

          Map.put(acc, relation, rows)

        [name_block] ->
          relation = String.trim(name_block)
          Map.put(acc, relation, [])

        _ ->
          acc
      end
    end)
  end

  # --- Private ---

  defp run_souffle(program) do
    souffle = Application.get_env(:home_agent, :souffle_bin, "souffle")
    tmp = Path.join(System.tmp_dir!(), "automaton_#{:erlang.unique_integer([:positive])}.dl")
    File.write!(tmp, program)

    result =
      try do
        case System.cmd(souffle, ["-D-", tmp], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, parse_output(output)}

          {error_output, code} ->
            Logger.warning("RuleEngine: souffle exited #{code}:\n#{error_output}")
            {:error, {:souffle_error, code, error_output}}
        end
      rescue
        ErlangError ->
          Logger.warning("RuleEngine: souffle binary not found (#{souffle})")
          {:error, :souffle_not_found}
      end

    File.rm(tmp)
    result
  end

  defp read_static_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        Logger.warning("RuleEngine: static file not found: #{path}")
        {:ok, ""}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
