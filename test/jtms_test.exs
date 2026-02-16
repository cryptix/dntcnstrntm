defmodule Propagator.JTMSTest do
  use ExUnit.Case, async: true

  alias Propagator.JTMS

  # --- Helpers ---

  defp new_jtms!(nodes) do
    {:ok, jtms} = JTMS.new()
    Enum.each(nodes, &JTMS.create_node(jtms, &1))
    jtms
  end

  # --- Node basics ---

  describe "node creation" do
    test "new nodes start :out" do
      jtms = new_jtms!([:a, :b])
      assert JTMS.node_out?(jtms, :a)
      assert JTMS.node_out?(jtms, :b)
    end

    test "creating the same node twice is idempotent" do
      jtms = new_jtms!([:a])
      JTMS.create_node(jtms, :a)
      assert JTMS.node_out?(jtms, :a)
    end

    test "new nodes are not assumptions" do
      jtms = new_jtms!([:a])
      refute JTMS.assumption?(jtms, :a)
    end

    test "new nodes have no supporting justification" do
      jtms = new_jtms!([:a])
      assert JTMS.why(jtms, :a) == nil
    end
  end

  # --- Assumptions ---

  describe "assume_node" do
    test "assuming a node makes it :in" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      assert JTMS.node_in?(jtms, :a)
    end

    test "assumed node is flagged as assumption" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      assert JTMS.assumption?(jtms, :a)
    end

    test "assumed node has :assumption as its support informant" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      assert JTMS.why(jtms, :a).informant == :assumption
    end
  end

  # --- Retraction ---

  describe "retract_assumption" do
    test "retracting an assumption makes the node :out" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      assert JTMS.node_in?(jtms, :a)

      JTMS.retract_assumption(jtms, :a)
      assert JTMS.node_out?(jtms, :a)
    end

    test "retracted node is no longer flagged as assumption" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      JTMS.retract_assumption(jtms, :a)
      refute JTMS.assumption?(jtms, :a)
    end

    test "retracted node has no support" do
      jtms = new_jtms!([:a])
      JTMS.assume_node(jtms, :a)
      JTMS.retract_assumption(jtms, :a)
      assert JTMS.why(jtms, :a) == nil
    end
  end

  # --- Simple justifications (monotonic) ---

  describe "justify_node (monotonic)" do
    test "node with satisfied justification becomes :in" do
      jtms = new_jtms!([:a, :b])
      JTMS.assume_node(jtms, :a)
      JTMS.justify_node(jtms, :b, :rule1, [:a])
      assert JTMS.node_in?(jtms, :b)
    end

    test "node with unsatisfied justification stays :out" do
      jtms = new_jtms!([:a, :b])
      # :a is :out, so justification for :b is not yet valid
      JTMS.justify_node(jtms, :b, :rule1, [:a])
      assert JTMS.node_out?(jtms, :b)
    end

    test "node becomes :in when its antecedent is later assumed" do
      jtms = new_jtms!([:a, :b])
      JTMS.justify_node(jtms, :b, :rule1, [:a])
      assert JTMS.node_out?(jtms, :b)

      JTMS.assume_node(jtms, :a)
      assert JTMS.node_in?(jtms, :b)
    end

    test "justification with multiple antecedents — all must be :in" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.justify_node(jtms, :c, :rule1, [:a, :b])

      JTMS.assume_node(jtms, :a)
      assert JTMS.node_out?(jtms, :c)

      JTMS.assume_node(jtms, :b)
      assert JTMS.node_in?(jtms, :c)
    end

    test "why returns the supporting justification" do
      jtms = new_jtms!([:a, :b])
      JTMS.assume_node(jtms, :a)
      JTMS.justify_node(jtms, :b, :rule1, [:a])
      assert JTMS.why(jtms, :b).informant == :rule1
    end
  end

  # --- Propagation chains ---

  describe "label propagation" do
    test "chain: A → B → C" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.justify_node(jtms, :b, :r1, [:a])
      JTMS.justify_node(jtms, :c, :r2, [:b])

      JTMS.assume_node(jtms, :a)
      assert JTMS.node_in?(jtms, :a)
      assert JTMS.node_in?(jtms, :b)
      assert JTMS.node_in?(jtms, :c)
    end

    test "retraction propagates through chain" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.justify_node(jtms, :b, :r1, [:a])
      JTMS.justify_node(jtms, :c, :r2, [:b])
      JTMS.assume_node(jtms, :a)

      JTMS.retract_assumption(jtms, :a)
      assert JTMS.node_out?(jtms, :a)
      assert JTMS.node_out?(jtms, :b)
      assert JTMS.node_out?(jtms, :c)
    end

    test "diamond: A → B, A → C, B+C → D" do
      jtms = new_jtms!([:a, :b, :c, :d])
      JTMS.justify_node(jtms, :b, :r1, [:a])
      JTMS.justify_node(jtms, :c, :r2, [:a])
      JTMS.justify_node(jtms, :d, :r3, [:b, :c])

      JTMS.assume_node(jtms, :a)
      assert JTMS.node_in?(jtms, :d)

      JTMS.retract_assumption(jtms, :a)
      assert JTMS.node_out?(jtms, :d)
    end
  end

  # --- Multiple justifications (redundant support) ---

  describe "multiple justifications" do
    test "node with two justifications stays :in when one is retracted" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.assume_node(jtms, :a)
      JTMS.assume_node(jtms, :b)
      JTMS.justify_node(jtms, :c, :via_a, [:a])
      JTMS.justify_node(jtms, :c, :via_b, [:b])

      assert JTMS.node_in?(jtms, :c)

      JTMS.retract_assumption(jtms, :a)
      # Still :in via :b
      assert JTMS.node_in?(jtms, :c)
    end

    test "node goes :out only when all justifications are invalidated" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.assume_node(jtms, :a)
      JTMS.assume_node(jtms, :b)
      JTMS.justify_node(jtms, :c, :via_a, [:a])
      JTMS.justify_node(jtms, :c, :via_b, [:b])

      JTMS.retract_assumption(jtms, :a)
      JTMS.retract_assumption(jtms, :b)
      assert JTMS.node_out?(jtms, :c)
    end
  end

  # --- Non-monotonic justifications (out-list) ---

  describe "non-monotonic justifications" do
    test "node is :in when out-list node is :out (default reasoning)" do
      # "birds fly unless proven otherwise"
      jtms = new_jtms!([:bird, :abnormal, :flies])
      JTMS.assume_node(jtms, :bird)
      JTMS.justify_node(jtms, :flies, :default_rule, [:bird], [:abnormal])

      assert JTMS.node_in?(jtms, :flies)
    end

    test "node goes :out when out-list node becomes :in" do
      # Tweety is a penguin → abnormal → no longer flies
      jtms = new_jtms!([:bird, :abnormal, :flies])
      JTMS.assume_node(jtms, :bird)
      JTMS.justify_node(jtms, :flies, :default_rule, [:bird], [:abnormal])
      assert JTMS.node_in?(jtms, :flies)

      JTMS.assume_node(jtms, :abnormal)
      assert JTMS.node_out?(jtms, :flies)
    end

    test "node becomes :in again when out-list node is retracted" do
      jtms = new_jtms!([:bird, :abnormal, :flies])
      JTMS.assume_node(jtms, :bird)
      JTMS.justify_node(jtms, :flies, :default_rule, [:bird], [:abnormal])

      JTMS.assume_node(jtms, :abnormal)
      assert JTMS.node_out?(jtms, :flies)

      JTMS.retract_assumption(jtms, :abnormal)
      assert JTMS.node_in?(jtms, :flies)
    end

    test "pure out-list justification (closed-world assumption)" do
      # "innocent until proven guilty"
      jtms = new_jtms!([:guilty, :innocent])
      JTMS.justify_node(jtms, :innocent, :presumption, [], [:guilty])

      assert JTMS.node_in?(jtms, :innocent)

      JTMS.assume_node(jtms, :guilty)
      assert JTMS.node_out?(jtms, :innocent)

      JTMS.retract_assumption(jtms, :guilty)
      assert JTMS.node_in?(jtms, :innocent)
    end

    test "non-monotonic chain: A out → B in → C in, then A in → B out → C out" do
      jtms = new_jtms!([:a, :b, :c])
      JTMS.justify_node(jtms, :b, :r1, [], [:a])
      JTMS.justify_node(jtms, :c, :r2, [:b])

      # A is :out, so B is :in (via out-list), and C follows
      assert JTMS.node_in?(jtms, :b)
      assert JTMS.node_in?(jtms, :c)

      # Now assume A — B loses its justification, C follows
      JTMS.assume_node(jtms, :a)
      assert JTMS.node_out?(jtms, :b)
      assert JTMS.node_out?(jtms, :c)

      # Retract A — everything goes back
      JTMS.retract_assumption(jtms, :a)
      assert JTMS.node_in?(jtms, :b)
      assert JTMS.node_in?(jtms, :c)
    end
  end

  # --- Classic scenario: Tweety the Penguin ---

  describe "classic JTMS scenario" do
    test "Tweety the penguin: default reasoning with exception" do
      jtms = new_jtms!([:tweety_bird, :tweety_penguin, :tweety_abnormal, :tweety_flies])

      # Rule: penguins are abnormal (w.r.t. flying)
      JTMS.justify_node(jtms, :tweety_abnormal, :penguin_rule, [:tweety_penguin])

      # Rule: birds fly unless abnormal
      JTMS.justify_node(jtms, :tweety_flies, :flying_rule, [:tweety_bird], [:tweety_abnormal])

      # Fact: Tweety is a bird
      JTMS.assume_node(jtms, :tweety_bird)
      assert JTMS.node_in?(jtms, :tweety_flies)

      # New fact: Tweety is a penguin
      JTMS.assume_node(jtms, :tweety_penguin)
      assert JTMS.node_in?(jtms, :tweety_abnormal)
      assert JTMS.node_out?(jtms, :tweety_flies)

      # Oops, Tweety is not a penguin after all
      JTMS.retract_assumption(jtms, :tweety_penguin)
      assert JTMS.node_out?(jtms, :tweety_abnormal)
      assert JTMS.node_in?(jtms, :tweety_flies)
    end
  end
end
