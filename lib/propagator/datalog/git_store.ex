defmodule Propagator.Datalog.GitStore do
  @moduledoc """
  Git-backed persistence for Datalog facts.

  Manages a git repository where each commit captures the full belief state
  of a propagator network as Datalog files. Provides introspection through
  standard git operations: log, diff, blame, and per-file history.

  ## Usage

      # Initialize a knowledge repo
      {:ok, store} = GitStore.init("/tmp/winter-knowledge")

      # Snapshot the current network state
      {:ok, sha} = GitStore.snapshot(store, domain, "Sensor reading: temperature 75°F")

      # Later, after retraction and new assertion...
      {:ok, sha} = GitStore.snapshot(store, domain, "Temperature updated to 78°F")

      # Introspect
      {:ok, log} = GitStore.log(store)
      {:ok, diff} = GitStore.diff(store, "HEAD~1")
      {:ok, history} = GitStore.history(store, "cells/temperature.dl")

  ## Branching for what-if reasoning

      # Try a hypothetical on a branch
      :ok = GitStore.branch(store, "what-if-hot")
      {:ok, _} = GitStore.snapshot(store, domain, "What if temperature is 90°F?")

      # Compare with main worldview
      {:ok, diff} = GitStore.diff_branches(store, "main", "what-if-hot")

      # Discard or merge
      :ok = GitStore.checkout(store, "main")

  This maps directly to the ATMS limitation noted in the README:
  JTMS is single-context, but git branches give you named contexts
  you can diff and merge.
  """

  alias Propagator.Datalog
  alias Propagator.Network

  defstruct [:path]

  @doc """
  Initialize a new knowledge repository at `path`.

  Creates the directory, runs `git init`, and makes an initial empty commit
  so that subsequent diffs have a base to compare against.
  """
  def init(path) do
    store = %__MODULE__{path: path}

    with :ok <- ensure_dir(path),
         :ok <- git(store, ["init", "-b", "main"]),
         :ok <- git(store, ["config", "user.email", "propagator@local"]),
         :ok <- git(store, ["config", "user.name", "propagator"]),
         :ok <- git(store, ["config", "commit.gpgsign", "false"]),
         :ok <- git(store, ["config", "tag.gpgsign", "false"]),
         :ok <- write_file(store, ".gitkeep", ""),
         :ok <- git(store, ["add", "."]),
         :ok <- git(store, ["commit", "-m", "Initialize knowledge base", "--allow-empty"]) do
      {:ok, store}
    end
  end

  @doc """
  Open an existing knowledge repository at `path`.

  Returns `{:error, :not_a_repo}` if the path doesn't contain a git repo.
  """
  def open(path) do
    store = %__MODULE__{path: path}

    case git_result(store, ["status"]) do
      {_, 0} -> {:ok, store}
      _ -> {:error, :not_a_repo}
    end
  end

  @doc """
  Snapshot the current network state as a git commit.

  Serializes the domain's beliefs to Datalog files, stages all changes,
  and commits with the given message. Returns `{:ok, commit_sha}`.
  """
  def snapshot(store, domain, message) do
    net = domain.__struct__.network(domain)
    state = Network.inspect_state(net)
    files = Datalog.serialize(domain, state)

    # Write all files
    Enum.each(files, fn {path, content} ->
      write_file(store, path, content)
    end)

    # Stage and commit
    with :ok <- git(store, ["add", "-A"]),
         :ok <- git_commit(store, message) do
      sha = git_output(store, ["rev-parse", "--short", "HEAD"])
      {:ok, String.trim(sha)}
    end
  end

  @doc """
  Get the git log. Options:

  - `:limit` — max number of entries (default 20)
  - `:path` — restrict to a specific file path
  - `:format` — git log format string (default: `"%h %s"`)
  """
  def log(store, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    format = Keyword.get(opts, :format, "%h %s")
    path = Keyword.get(opts, :path, nil)

    args = ["log", "--oneline", "-n", "#{limit}", "--format=#{format}"]
    args = if path, do: args ++ ["--", path], else: args

    {:ok, git_output(store, args)}
  end

  @doc """
  Get a structured git log as a list of maps.

  Each entry has `:sha`, `:message`, `:timestamp`, and `:author`.
  """
  def log_entries(store, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    path = Keyword.get(opts, :path, nil)

    args = ["log", "-n", "#{limit}", "--format=%H|%s|%ai|%an"]
    args = if path, do: args ++ ["--", path], else: args

    output = git_output(store, args)

    entries =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, "|", parts: 4) do
          [sha, message, timestamp, author] ->
            %{sha: sha, message: message, timestamp: timestamp, author: author}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, entries}
  end

  @doc """
  Diff against a reference (e.g. `"HEAD~1"`, a commit SHA, or a branch name).
  """
  def diff(store, ref) do
    {:ok, git_output(store, ["diff", ref])}
  end

  @doc """
  Diff between two refs (e.g. two branches or two commits).
  """
  def diff_refs(store, ref_a, ref_b) do
    {:ok, git_output(store, ["diff", ref_a, ref_b])}
  end

  @doc """
  Show the history of a specific file.
  """
  def history(store, file_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    {:ok, git_output(store, ["log", "-n", "#{limit}", "--follow", "-p", "--", file_path])}
  end

  @doc """
  Show git blame for a file — which commit introduced each line.
  """
  def blame(store, file_path) do
    {:ok, git_output(store, ["blame", file_path])}
  end

  @doc """
  Read a file's content at a specific ref (commit/branch/tag).
  """
  def show(store, ref, file_path) do
    {:ok, git_output(store, ["show", "#{ref}:#{file_path}"])}
  end

  @doc """
  Create a new branch (for what-if reasoning).
  """
  def branch(store, name) do
    git(store, ["checkout", "-b", name])
  end

  @doc """
  Switch to an existing branch.
  """
  def checkout(store, name) do
    git(store, ["checkout", name])
  end

  @doc """
  List all branches.
  """
  def branches(store) do
    output = git_output(store, ["branch", "--list", "--no-color"])

    branches =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        current? = String.starts_with?(line, "* ")
        name = String.trim_leading(line, "* ") |> String.trim()
        {name, current?}
      end)

    {:ok, branches}
  end

  @doc """
  Tag the current commit (for naming important states).
  """
  def tag(store, name, message \\ nil) do
    args = if message, do: ["tag", "-a", name, "-m", message], else: ["tag", name]
    git(store, args)
  end

  @doc """
  List all tags.
  """
  def tags(store) do
    {:ok, git_output(store, ["tag", "--list"])}
  end

  @doc """
  Read a Datalog cell file at the current HEAD and parse it.
  """
  def read_cell(store, cell_name) do
    path = Path.join(store.path, "cells/#{cell_name}.dl")

    case File.read(path) do
      {:ok, content} -> {:ok, Datalog.parse_cell(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read a Datalog cell file at a specific ref and parse it.
  """
  def read_cell_at(store, cell_name, ref) do
    case show(store, ref, "cells/#{cell_name}.dl") do
      {:ok, content} -> {:ok, Datalog.parse_cell(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Git helpers ---

  defp git(store, args) do
    case git_result(store, args) do
      {_, 0} -> :ok
      {output, code} -> {:error, {code, output}}
    end
  end

  defp git_output(store, args) do
    {output, 0} = git_result(store, args)
    String.trim(output)
  end

  defp git_result(store, args) do
    System.cmd("git", args, cd: store.path, stderr_to_stdout: true)
  end

  defp git_commit(store, message) do
    # Check if there are staged changes
    case git_result(store, ["diff", "--cached", "--quiet"]) do
      {_, 0} ->
        # No changes staged — skip commit
        :ok

      {_, 1} ->
        # Changes staged — commit them
        git(store, ["commit", "-m", message])
    end
  end

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  defp write_file(store, relative_path, content) do
    full_path = Path.join(store.path, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
    :ok
  end
end
