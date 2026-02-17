defmodule Propagator.ComplexScenariosTest do
  @moduledoc """
  Complex, practical test scenarios that showcase the system's capabilities
  across all four phases. Each test models a real-world problem domain.
  """
  use ExUnit.Case, async: true

  alias Propagator.Network
  alias Propagator.Network.Arithmetic
  alias Propagator.JTMS
  alias Propagator.Lattice.Set
  alias Propagator.Solver.AC3

  @settle 50

  # ============================================================================
  # Phase 3 (Network): Ohm's Law Circuit
  #
  # V = I * R (Voltage = Current × Resistance)
  #
  # A practical electrical engineering scenario: a circuit with a resistor,
  # multiple measurement instruments (multimeters), and the ability to
  # retract faulty readings. Demonstrates bidirectional constraint solving
  # with belief tracking.
  # ============================================================================

  describe "Ohm's Law circuit (Network)" do
    defp build_ohms_law_network do
      {:ok, net} = Network.new()
      voltage = Network.create_cell(net)
      current = Network.create_cell(net)
      resistance = Network.create_cell(net)

      # V = I * R  (bidirectional)
      Arithmetic.multiplier(net, current, resistance, voltage)
      Process.sleep(@settle)

      {net, voltage, current, resistance}
    end

    test "forward: given current and resistance, compute voltage" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, current, 2.0, :ammeter)
      Network.add_content(net, resistance, 100, :ohmmeter)
      Process.sleep(@settle)

      # V = 2A × 100Ω = 200V
      assert_in_delta Network.read_cell(net, voltage), 200.0, 0.001
    end

    test "backward: given voltage and resistance, solve for current" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, voltage, 12.0, :voltmeter)
      Network.add_content(net, resistance, 4, :ohmmeter)
      Process.sleep(@settle)

      # I = V/R = 12V / 4Ω = 3A
      assert_in_delta Network.read_cell(net, current), 3.0, 0.001
    end

    test "backward: given voltage and current, solve for resistance" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, voltage, 9.0, :voltmeter)
      Network.add_content(net, current, 0.5, :ammeter)
      Process.sleep(@settle)

      # R = V/I = 9V / 0.5A = 18Ω
      assert_in_delta Network.read_cell(net, resistance), 18.0, 0.001
    end

    test "two voltmeters agree — redundant confirmation" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, current, 3.0, :ammeter)
      Network.add_content(net, resistance, 50, :ohmmeter)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, voltage), 150.0, 0.001

      # Second voltmeter confirms the same reading
      Network.add_content(net, voltage, 150.0, :voltmeter_2)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, voltage), 150.0, 0.001
    end

    test "faulty ammeter causes contradiction, retract to fix" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      # The real circuit: 5V across 10Ω → 0.5A
      Network.add_content(net, voltage, 5.0, :voltmeter)
      Network.add_content(net, resistance, 10, :ohmmeter)
      Process.sleep(@settle)

      # Derived: I = 0.5A
      assert_in_delta Network.read_cell(net, current), 0.5, 0.001

      # Faulty ammeter reads 2.0A — contradicts derived 0.5A
      Network.add_content(net, current, 2.0, :faulty_ammeter)
      Process.sleep(@settle)

      assert Network.read_cell(net, current) == :contradiction

      # Technician identifies faulty ammeter and removes it
      Network.retract_content(net, current, :faulty_ammeter)
      Process.sleep(@settle)

      # System recovers — derived current is back
      assert_in_delta Network.read_cell(net, current), 0.5, 0.001
    end

    test "replace resistance measurement, derived values update" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, current, 2.0, :ammeter)
      Network.add_content(net, resistance, 50, :ohmmeter_v1)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, voltage), 100.0, 0.001

      # Ohmmeter was miscalibrated — retract and re-measure
      Network.retract_content(net, resistance, :ohmmeter_v1)
      Network.add_content(net, resistance, 75, :ohmmeter_v2)
      Process.sleep(@settle)

      # V = 2A × 75Ω = 150V
      assert_in_delta Network.read_cell(net, voltage), 150.0, 0.001
    end

    test "retract all measurements — network returns to unknown" do
      {net, voltage, current, resistance} = build_ohms_law_network()

      Network.add_content(net, current, 1.0, :ammeter)
      Network.add_content(net, resistance, 220, :ohmmeter)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, voltage), 220.0, 0.001

      # Remove all instruments
      Network.retract_content(net, current, :ammeter)
      Network.retract_content(net, resistance, :ohmmeter)
      Process.sleep(@settle)

      assert Network.read_cell(net, voltage) == :nothing
      assert Network.read_cell(net, current) == :nothing
      assert Network.read_cell(net, resistance) == :nothing
    end
  end

  # ============================================================================
  # Phase 2 (JTMS): Medical Diagnosis with Competing Hypotheses
  #
  # A patient presents with symptoms. Default reasoning suggests initial
  # diagnoses, but lab results and specialist opinions can override them.
  # Demonstrates non-monotonic reasoning, multiple competing defaults,
  # and belief revision chains in a realistic setting.
  # ============================================================================

  describe "medical diagnosis (JTMS)" do
    defp new_jtms!(nodes) do
      {:ok, jtms} = JTMS.new()
      Enum.each(nodes, &JTMS.create_node(jtms, &1))
      jtms
    end

    test "default diagnosis from symptoms, overridden by lab results" do
      jtms =
        new_jtms!([
          :fever,
          :cough,
          :sore_throat,
          :bacterial_infection,
          :viral_flu,
          :treat_antibiotics,
          :treat_rest_fluids
        ])

      # Rule: fever + cough → default diagnosis: viral flu (unless bacterial)
      JTMS.justify_node(jtms, :viral_flu, :default_flu_rule, [:fever, :cough], [:bacterial_infection])

      # Rule: viral flu → treat with rest and fluids
      JTMS.justify_node(jtms, :treat_rest_fluids, :flu_treatment, [:viral_flu])

      # Rule: bacterial infection → treat with antibiotics
      JTMS.justify_node(jtms, :treat_antibiotics, :antibiotic_rule, [:bacterial_infection])

      # Patient presents with fever and cough
      JTMS.assume_node(jtms, :fever)
      JTMS.assume_node(jtms, :cough)

      # Default: viral flu diagnosed, rest prescribed
      assert JTMS.node_in?(jtms, :viral_flu)
      assert JTMS.node_in?(jtms, :treat_rest_fluids)
      assert JTMS.node_out?(jtms, :treat_antibiotics)

      # Lab results come back: strep test positive → bacterial
      JTMS.assume_node(jtms, :bacterial_infection)

      # Viral flu retracted (non-monotonic), antibiotics now indicated
      assert JTMS.node_out?(jtms, :viral_flu)
      assert JTMS.node_out?(jtms, :treat_rest_fluids)
      assert JTMS.node_in?(jtms, :treat_antibiotics)

      # Lab was a false positive — retract bacterial diagnosis
      JTMS.retract_assumption(jtms, :bacterial_infection)

      # Back to default: viral flu
      assert JTMS.node_in?(jtms, :viral_flu)
      assert JTMS.node_in?(jtms, :treat_rest_fluids)
      assert JTMS.node_out?(jtms, :treat_antibiotics)
    end

    test "multiple symptoms narrow diagnosis through cascading rules" do
      jtms =
        new_jtms!([
          :fever,
          :cough,
          :chest_pain,
          :shortness_of_breath,
          :common_cold,
          :pneumonia,
          :hospitalize,
          :outpatient
        ])

      # Rule: fever + cough → common cold (default, unless more severe signs)
      JTMS.justify_node(jtms, :common_cold, :cold_default, [:fever, :cough], [:pneumonia])

      # Rule: common cold → outpatient treatment
      JTMS.justify_node(jtms, :outpatient, :outpatient_rule, [:common_cold])

      # Rule: fever + cough + chest_pain + shortness_of_breath → pneumonia
      JTMS.justify_node(jtms, :pneumonia, :pneumonia_rule, [:fever, :cough, :chest_pain, :shortness_of_breath])

      # Rule: pneumonia → hospitalize
      JTMS.justify_node(jtms, :hospitalize, :hospitalize_rule, [:pneumonia])

      # Initially: just fever and cough
      JTMS.assume_node(jtms, :fever)
      JTMS.assume_node(jtms, :cough)

      assert JTMS.node_in?(jtms, :common_cold)
      assert JTMS.node_in?(jtms, :outpatient)
      assert JTMS.node_out?(jtms, :pneumonia)
      assert JTMS.node_out?(jtms, :hospitalize)

      # Patient develops chest pain and shortness of breath
      JTMS.assume_node(jtms, :chest_pain)
      JTMS.assume_node(jtms, :shortness_of_breath)

      # Now pneumonia is diagnosed, overriding common cold default
      assert JTMS.node_in?(jtms, :pneumonia)
      assert JTMS.node_in?(jtms, :hospitalize)
      assert JTMS.node_out?(jtms, :common_cold)
      assert JTMS.node_out?(jtms, :outpatient)

      # Chest X-ray comes back clear — retract chest pain (misreported)
      JTMS.retract_assumption(jtms, :chest_pain)

      # Back to common cold (pneumonia no longer justified)
      assert JTMS.node_out?(jtms, :pneumonia)
      assert JTMS.node_out?(jtms, :hospitalize)
      assert JTMS.node_in?(jtms, :common_cold)
      assert JTMS.node_in?(jtms, :outpatient)
    end

    test "redundant evidence: two independent reasons to believe diagnosis" do
      jtms =
        new_jtms!([
          :positive_culture,
          :positive_rapid_test,
          :strep_throat,
          :prescribe_amoxicillin
        ])

      # Either test independently justifies strep diagnosis
      JTMS.justify_node(jtms, :strep_throat, :culture_evidence, [:positive_culture])
      JTMS.justify_node(jtms, :strep_throat, :rapid_test_evidence, [:positive_rapid_test])

      # Treatment follows from diagnosis
      JTMS.justify_node(jtms, :prescribe_amoxicillin, :strep_treatment, [:strep_throat])

      JTMS.assume_node(jtms, :positive_culture)
      JTMS.assume_node(jtms, :positive_rapid_test)

      assert JTMS.node_in?(jtms, :strep_throat)
      assert JTMS.node_in?(jtms, :prescribe_amoxicillin)

      # Culture was contaminated — retract it
      JTMS.retract_assumption(jtms, :positive_culture)

      # Still diagnosed via rapid test
      assert JTMS.node_in?(jtms, :strep_throat)
      assert JTMS.node_in?(jtms, :prescribe_amoxicillin)

      # Rapid test also retracted (false positive)
      JTMS.retract_assumption(jtms, :positive_rapid_test)

      # Now no evidence → no diagnosis → no treatment
      assert JTMS.node_out?(jtms, :strep_throat)
      assert JTMS.node_out?(jtms, :prescribe_amoxicillin)
    end
  end

  # ============================================================================
  # Phase 3 (Network): Project Cost Estimation with Corrections
  #
  # A multi-step financial calculation:
  #   subtotal = labor + materials
  #   tax = subtotal × tax_rate
  #   total = subtotal + tax
  #
  # Demonstrates deep propagation chains, correction of upstream estimates,
  # and cascading recalculation through the entire pipeline.
  # ============================================================================

  describe "project cost estimation (Network)" do
    defp build_cost_network do
      {:ok, net} = Network.new()
      labor = Network.create_cell(net)
      materials = Network.create_cell(net)
      subtotal = Network.create_cell(net)
      tax_rate = Network.create_cell(net)
      tax = Network.create_cell(net)
      total = Network.create_cell(net)

      # subtotal = labor + materials
      Arithmetic.adder(net, labor, materials, subtotal)

      # tax = subtotal × tax_rate
      Arithmetic.multiplier(net, subtotal, tax_rate, tax)

      # total = subtotal + tax
      Arithmetic.adder(net, subtotal, tax, total)

      Process.sleep(@settle)

      {net, labor, materials, subtotal, tax_rate, tax, total}
    end

    test "forward: compute total from labor, materials, and tax rate" do
      {net, labor, materials, _subtotal, tax_rate, _tax, total} = build_cost_network()

      Network.add_content(net, labor, 5000, :estimate_labor)
      Network.add_content(net, materials, 3000, :estimate_materials)
      Network.add_content(net, tax_rate, 0.1, :tax_authority)
      Process.sleep(@settle)

      # subtotal = 8000, tax = 800, total = 8800
      assert_in_delta Network.read_cell(net, total), 8800.0, 0.01
    end

    test "backward: given total and subtotal, derive tax" do
      {net, labor, materials, subtotal, tax_rate, tax, total} = build_cost_network()

      Network.add_content(net, labor, 5000, :labor_est)
      Network.add_content(net, materials, 5000, :material_est)
      Network.add_content(net, tax_rate, 0.1, :tax_authority)
      Process.sleep(@settle)

      # subtotal = 10000, tax = 1000, total = 11000
      assert_in_delta Network.read_cell(net, subtotal), 10000.0, 0.01
      assert_in_delta Network.read_cell(net, tax), 1000.0, 0.01
      assert_in_delta Network.read_cell(net, total), 11000.0, 0.01
    end

    test "correct labor estimate — total updates through full chain" do
      {net, labor, materials, subtotal, tax_rate, tax, total} = build_cost_network()

      Network.add_content(net, labor, 5000, :initial_estimate)
      Network.add_content(net, materials, 3000, :vendor_quote)
      Network.add_content(net, tax_rate, 0.1, :tax_authority)
      Process.sleep(@settle)

      # Initial: subtotal=8000, tax=800, total=8800
      assert_in_delta Network.read_cell(net, total), 8800.0, 0.01

      # Labor estimate was wrong — retract and correct
      Network.retract_content(net, labor, :initial_estimate)
      Network.add_content(net, labor, 7000, :revised_estimate)
      Process.sleep(@settle)

      # Revised: subtotal=10000, tax=1000, total=11000
      assert_in_delta Network.read_cell(net, subtotal), 10000.0, 0.01
      assert_in_delta Network.read_cell(net, tax), 1000.0, 0.01
      assert_in_delta Network.read_cell(net, total), 11000.0, 0.01
    end

    test "retract all inputs — entire pipeline goes unknown" do
      {net, labor, materials, subtotal, tax_rate, tax, total} = build_cost_network()

      Network.add_content(net, labor, 5000, :est)
      Network.add_content(net, materials, 3000, :est)
      Network.add_content(net, tax_rate, 0.1, :est)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, total), 8800.0, 0.01

      # Client cancels — retract everything
      Network.retract_content(net, labor, :est)
      Network.retract_content(net, materials, :est)
      Network.retract_content(net, tax_rate, :est)
      Process.sleep(@settle)

      assert Network.read_cell(net, subtotal) == :nothing
      assert Network.read_cell(net, tax) == :nothing
      assert Network.read_cell(net, total) == :nothing
    end

    test "two vendors quote materials, retract losing bid" do
      {net, labor, materials, _subtotal, tax_rate, _tax, total} = build_cost_network()

      Network.add_content(net, labor, 5000, :labor_est)
      Network.add_content(net, tax_rate, 0.1, :tax_authority)

      # Two vendors quote the same price
      Network.add_content(net, materials, 3000, :vendor_a)
      Network.add_content(net, materials, 3000, :vendor_b)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, total), 8800.0, 0.01

      # Vendor A drops out — still have vendor B's quote
      Network.retract_content(net, materials, :vendor_a)
      Process.sleep(@settle)

      assert_in_delta Network.read_cell(net, total), 8800.0, 0.01
    end
  end

  # ============================================================================
  # Phase 2 (JTMS): Software Configuration Dependencies
  #
  # Models a package-manager-like system where features have dependencies
  # and conflicts. Demonstrates non-monotonic reasoning for default choices,
  # dependency chains, and conflict resolution via retraction.
  # ============================================================================

  describe "configuration dependencies (JTMS)" do
    test "installing a feature pulls in its dependencies" do
      jtms =
        new_jtms!([
          :web_app,
          :web_framework,
          :database_driver,
          :connection_pool
        ])

      # web_app requires web_framework
      JTMS.justify_node(jtms, :web_framework, :dep_web, [:web_app])
      # web_framework requires database_driver
      JTMS.justify_node(jtms, :database_driver, :dep_db, [:web_framework])
      # database_driver requires connection_pool
      JTMS.justify_node(jtms, :connection_pool, :dep_pool, [:database_driver])

      # Install the web app
      JTMS.assume_node(jtms, :web_app)

      # All dependencies should be pulled in
      assert JTMS.node_in?(jtms, :web_framework)
      assert JTMS.node_in?(jtms, :database_driver)
      assert JTMS.node_in?(jtms, :connection_pool)

      # Uninstall the web app — entire dependency chain retracts
      JTMS.retract_assumption(jtms, :web_app)

      assert JTMS.node_out?(jtms, :web_framework)
      assert JTMS.node_out?(jtms, :database_driver)
      assert JTMS.node_out?(jtms, :connection_pool)
    end

    test "default database overridden by premium selection" do
      jtms =
        new_jtms!([
          :app,
          :needs_database,
          :premium_db,
          :default_db,
          :use_premium,
          :use_default
        ])

      # App needs a database
      JTMS.justify_node(jtms, :needs_database, :app_dep, [:app])

      # Default: use free database (unless premium is chosen)
      JTMS.justify_node(jtms, :use_default, :default_choice, [:needs_database], [:use_premium])

      # Premium overrides default when selected
      JTMS.justify_node(jtms, :use_premium, :premium_choice, [:needs_database, :premium_db])

      # Start: install app
      JTMS.assume_node(jtms, :app)

      # Default database is selected
      assert JTMS.node_in?(jtms, :needs_database)
      assert JTMS.node_in?(jtms, :use_default)
      assert JTMS.node_out?(jtms, :use_premium)

      # User opts for premium database
      JTMS.assume_node(jtms, :premium_db)

      # Premium overrides default
      assert JTMS.node_in?(jtms, :use_premium)
      assert JTMS.node_out?(jtms, :use_default)

      # User downgrades back to free tier
      JTMS.retract_assumption(jtms, :premium_db)

      assert JTMS.node_out?(jtms, :use_premium)
      assert JTMS.node_in?(jtms, :use_default)
    end

    test "feature conflict: enabling debug mode disables optimization" do
      jtms =
        new_jtms!([
          :app,
          :debug_mode,
          :optimization_on,
          :fast_execution,
          :detailed_logging
        ])

      # Default: optimization is on (unless debug mode)
      JTMS.justify_node(jtms, :optimization_on, :default_opt, [:app], [:debug_mode])
      JTMS.justify_node(jtms, :fast_execution, :opt_benefit, [:optimization_on])

      # Debug mode enables detailed logging
      JTMS.justify_node(jtms, :detailed_logging, :debug_logging, [:debug_mode])

      JTMS.assume_node(jtms, :app)

      # Default: optimized, fast, no logging
      assert JTMS.node_in?(jtms, :optimization_on)
      assert JTMS.node_in?(jtms, :fast_execution)
      assert JTMS.node_out?(jtms, :detailed_logging)

      # Enable debug mode
      JTMS.assume_node(jtms, :debug_mode)

      # Debug disables optimization, enables logging
      assert JTMS.node_out?(jtms, :optimization_on)
      assert JTMS.node_out?(jtms, :fast_execution)
      assert JTMS.node_in?(jtms, :detailed_logging)

      # Disable debug mode — back to optimized
      JTMS.retract_assumption(jtms, :debug_mode)

      assert JTMS.node_in?(jtms, :optimization_on)
      assert JTMS.node_in?(jtms, :fast_execution)
      assert JTMS.node_out?(jtms, :detailed_logging)
    end
  end

  # ============================================================================
  # Phase 4 (Solver): Map Coloring — Australia
  #
  # Classic CSP benchmark. Color 4 regions of Australia with 3 colors such
  # that no adjacent regions share a color. Demonstrates the AC-3 solver
  # on a well-known combinatorial problem.
  #
  # Simplified map:
  #   WA — NT — Q
  #    \   |   /
  #     \ SA  /
  #
  # Adjacencies: WA-NT, WA-SA, NT-SA, NT-Q, SA-Q
  # ============================================================================

  describe "map coloring — Australia (Solver)" do
    @colors Set.new([:red, :green, :blue])

    defp neq_constraint(var1, var2) do
      {[var1, var2], fn assignment ->
        if Map.has_key?(assignment, var1) and Map.has_key?(assignment, var2) do
          assignment[var1] != assignment[var2]
        else
          true
        end
      end}
    end

    test "4-region map is colorable with 3 colors" do
      variables = %{
        wa: @colors,
        nt: @colors,
        sa: @colors,
        q: @colors
      }

      constraints = [
        neq_constraint(:wa, :nt),
        neq_constraint(:wa, :sa),
        neq_constraint(:nt, :sa),
        neq_constraint(:nt, :q),
        neq_constraint(:sa, :q)
      ]

      assert {:ok, solution} = AC3.solve(variables, constraints)

      # All regions must have valid colors
      assert solution.wa in [:red, :green, :blue]
      assert solution.nt in [:red, :green, :blue]
      assert solution.sa in [:red, :green, :blue]
      assert solution.q in [:red, :green, :blue]

      # No adjacent regions share a color
      assert solution.wa != solution.nt
      assert solution.wa != solution.sa
      assert solution.nt != solution.sa
      assert solution.nt != solution.q
      assert solution.sa != solution.q
    end

    test "7-region map with more complex adjacency" do
      # Full Australian states: WA, NT, SA, Q, NSW, V, T
      # T (Tasmania) is isolated — no adjacency constraints
      variables = %{
        wa: @colors,
        nt: @colors,
        sa: @colors,
        q: @colors,
        nsw: @colors,
        v: @colors,
        t: @colors
      }

      constraints = [
        neq_constraint(:wa, :nt),
        neq_constraint(:wa, :sa),
        neq_constraint(:nt, :sa),
        neq_constraint(:nt, :q),
        neq_constraint(:sa, :q),
        neq_constraint(:sa, :nsw),
        neq_constraint(:sa, :v),
        neq_constraint(:q, :nsw),
        neq_constraint(:nsw, :v)
      ]

      assert {:ok, solution} = AC3.solve(variables, constraints)

      # Verify all adjacency constraints hold
      assert solution.wa != solution.nt
      assert solution.wa != solution.sa
      assert solution.nt != solution.sa
      assert solution.nt != solution.q
      assert solution.sa != solution.q
      assert solution.sa != solution.nsw
      assert solution.sa != solution.v
      assert solution.q != solution.nsw
      assert solution.nsw != solution.v
    end

    test "graph requiring exactly 3 colors (complete graph K3)" do
      # Triangle: A-B, B-C, A-C — needs at least 3 colors
      variables = %{
        a: @colors,
        b: @colors,
        c: @colors
      }

      constraints = [
        neq_constraint(:a, :b),
        neq_constraint(:b, :c),
        neq_constraint(:a, :c)
      ]

      assert {:ok, solution} = AC3.solve(variables, constraints)

      # Must use all 3 colors
      used_colors = MapSet.new([solution.a, solution.b, solution.c])
      assert MapSet.size(used_colors) == 3
    end

    test "K4 is not 3-colorable" do
      # Complete graph on 4 nodes: every pair adjacent — needs 4 colors
      variables = %{
        a: @colors,
        b: @colors,
        c: @colors,
        d: @colors
      }

      constraints = [
        neq_constraint(:a, :b),
        neq_constraint(:a, :c),
        neq_constraint(:a, :d),
        neq_constraint(:b, :c),
        neq_constraint(:b, :d),
        neq_constraint(:c, :d)
      ]

      assert {:error, :no_solution} = AC3.solve(variables, constraints)
    end
  end

  # ============================================================================
  # Phase 4 (Solver): Tests for existing example problems
  #
  # The examples in Propagator.Examples.Constraints define three practical
  # CSPs but they were never tested. Verify they produce valid solutions.
  # ============================================================================

  describe "example constraints — attention allocation (Solver)" do
    test "finds a valid attention allocation" do
      variables = %{
        coding: Set.new([0, 1, 2, 3, 4, 5]),
        reading: Set.new([0, 1, 2, 3, 4, 5]),
        exercise: Set.new([0, 1, 2, 3, 4, 5]),
        social: Set.new([0, 1, 2, 3, 4, 5])
      }

      total_budget =
        {[:coding, :reading, :exercise, :social], fn assignment ->
          if map_size(assignment) < 4 do
            true
          else
            total = assignment.coding + assignment.reading + assignment.exercise + assignment.social
            total <= 8
          end
        end}

      max_active_topics =
        {[:coding, :reading, :exercise, :social], fn assignment ->
          if map_size(assignment) < 4 do
            true
          else
            active_count =
              assignment
              |> Map.values()
              |> Enum.count(&(&1 > 0))

            active_count <= 3
          end
        end}

      assert {:ok, solution} = AC3.solve(variables, [total_budget, max_active_topics])

      # Verify budget constraint
      total = solution.coding + solution.reading + solution.exercise + solution.social
      assert total <= 8

      # Verify max topics constraint
      active = Enum.count(Map.values(solution), &(&1 > 0))
      assert active <= 3
    end
  end

  describe "example constraints — task scheduling (Solver)" do
    test "finds a valid schedule respecting dependencies and resource conflicts" do
      variables = %{
        task_a: Set.new([0, 1, 2, 3, 4, 5]),
        task_b: Set.new([0, 1, 2, 3, 4, 5]),
        task_c: Set.new([0, 1, 2, 3, 4, 5])
      }

      # task_b starts after task_a finishes (task_a duration = 2)
      dependency_a_b =
        {[:task_a, :task_b], fn assignment ->
          if Map.has_key?(assignment, :task_a) and Map.has_key?(assignment, :task_b) do
            assignment.task_b >= assignment.task_a + 2
          else
            true
          end
        end}

      # task_c starts after task_a finishes
      dependency_a_c =
        {[:task_a, :task_c], fn assignment ->
          if Map.has_key?(assignment, :task_a) and Map.has_key?(assignment, :task_c) do
            assignment.task_c >= assignment.task_a + 2
          else
            true
          end
        end}

      # task_b and task_c can't overlap (each duration 1)
      no_overlap_b_c =
        {[:task_b, :task_c], fn assignment ->
          if Map.has_key?(assignment, :task_b) and Map.has_key?(assignment, :task_c) do
            assignment.task_b != assignment.task_c
          else
            true
          end
        end}

      constraints = [dependency_a_b, dependency_a_c, no_overlap_b_c]

      assert {:ok, solution} = AC3.solve(variables, constraints)

      # Verify all constraints
      assert solution.task_b >= solution.task_a + 2, "B must start after A finishes"
      assert solution.task_c >= solution.task_a + 2, "C must start after A finishes"
      assert solution.task_b != solution.task_c, "B and C must not overlap"
    end

    test "tight schedule with deadline constraint" do
      # Same as above but tasks must complete by time 5
      variables = %{
        task_a: Set.new([0, 1, 2, 3]),
        task_b: Set.new([0, 1, 2, 3, 4]),
        task_c: Set.new([0, 1, 2, 3, 4])
      }

      dependency_a_b =
        {[:task_a, :task_b], fn a ->
          if Map.has_key?(a, :task_a) and Map.has_key?(a, :task_b),
            do: a.task_b >= a.task_a + 2,
            else: true
        end}

      dependency_a_c =
        {[:task_a, :task_c], fn a ->
          if Map.has_key?(a, :task_a) and Map.has_key?(a, :task_c),
            do: a.task_c >= a.task_a + 2,
            else: true
        end}

      no_overlap =
        {[:task_b, :task_c], fn a ->
          if Map.has_key?(a, :task_b) and Map.has_key?(a, :task_c),
            do: a.task_b != a.task_c,
            else: true
        end}

      # All tasks must finish by time 5
      deadline_b =
        {[:task_b], fn a ->
          if Map.has_key?(a, :task_b), do: a.task_b + 1 <= 5, else: true
        end}

      deadline_c =
        {[:task_c], fn a ->
          if Map.has_key?(a, :task_c), do: a.task_c + 1 <= 5, else: true
        end}

      constraints = [dependency_a_b, dependency_a_c, no_overlap, deadline_b, deadline_c]
      assert {:ok, solution} = AC3.solve(variables, constraints)

      assert solution.task_b >= solution.task_a + 2
      assert solution.task_c >= solution.task_a + 2
      assert solution.task_b != solution.task_c
      assert solution.task_b + 1 <= 5
      assert solution.task_c + 1 <= 5
    end
  end

  describe "example constraints — feature selection (Solver)" do
    test "finds a valid feature set within budget" do
      variables = %{
        core_auth: Set.new([0, 1]),
        core_db: Set.new([0, 1]),
        nice_ui: Set.new([0, 1]),
        nice_export: Set.new([0, 1])
      }

      must_have_auth =
        {[:core_auth], fn a ->
          if Map.has_key?(a, :core_auth), do: a.core_auth == 1, else: true
        end}

      must_have_db =
        {[:core_db], fn a ->
          if Map.has_key?(a, :core_db), do: a.core_db == 1, else: true
        end}

      budget_limit =
        {[:core_auth, :core_db, :nice_ui, :nice_export], fn a ->
          if map_size(a) < 4 do
            true
          else
            cost = a.core_auth * 3 + a.core_db * 4 + a.nice_ui * 2 + a.nice_export * 3
            cost <= 10
          end
        end}

      export_requires_db =
        {[:nice_export, :core_db], fn a ->
          if Map.has_key?(a, :nice_export) and Map.has_key?(a, :core_db) do
            a.nice_export == 0 or a.core_db == 1
          else
            true
          end
        end}

      constraints = [must_have_auth, must_have_db, budget_limit, export_requires_db]
      assert {:ok, solution} = AC3.solve(variables, constraints)

      # Core features must be included
      assert solution.core_auth == 1
      assert solution.core_db == 1

      # Budget not exceeded
      cost =
        solution.core_auth * 3 + solution.core_db * 4 +
          solution.nice_ui * 2 + solution.nice_export * 3

      assert cost <= 10

      # Dependency: if export is included, db must be included
      if solution.nice_export == 1 do
        assert solution.core_db == 1
      end
    end

    test "over-budget scenario has no solution" do
      # Increase costs so nothing fits
      variables = %{
        core_auth: Set.new([0, 1]),
        core_db: Set.new([0, 1]),
        nice_ui: Set.new([0, 1]),
        nice_export: Set.new([0, 1])
      }

      must_have_auth =
        {[:core_auth], fn a ->
          if Map.has_key?(a, :core_auth), do: a.core_auth == 1, else: true
        end}

      must_have_db =
        {[:core_db], fn a ->
          if Map.has_key?(a, :core_db), do: a.core_db == 1, else: true
        end}

      # Budget too small for mandatory features (auth=6 + db=6 = 12 > 10)
      tight_budget =
        {[:core_auth, :core_db, :nice_ui, :nice_export], fn a ->
          if map_size(a) < 4 do
            true
          else
            cost = a.core_auth * 6 + a.core_db * 6 + a.nice_ui * 2 + a.nice_export * 3
            cost <= 10
          end
        end}

      constraints = [must_have_auth, must_have_db, tight_budget]
      assert {:error, :no_solution} = AC3.solve(variables, constraints)
    end
  end

  # ============================================================================
  # Phase 4 (Solver): N-Queens (N=4)
  #
  # Place 4 queens on a 4×4 chessboard such that no two queens attack each
  # other. A well-known combinatorial benchmark.
  #
  # Variables: q1..q4 = column position of queen in each row
  # Constraints: no two queens share column or diagonal
  # ============================================================================

  describe "N-Queens (Solver)" do
    test "solves 4-Queens" do
      columns = Set.new([1, 2, 3, 4])

      variables = %{
        q1: columns,
        q2: columns,
        q3: columns,
        q4: columns
      }

      queens = [:q1, :q2, :q3, :q4]
      rows = %{q1: 1, q2: 2, q3: 3, q4: 4}

      # Generate all pairwise constraints: no shared column, no shared diagonal
      constraints =
        for qi <- queens,
            qj <- queens,
            qi < qj do
          {[qi, qj], fn assignment ->
            if Map.has_key?(assignment, qi) and Map.has_key?(assignment, qj) do
              ci = assignment[qi]
              cj = assignment[qj]
              ri = rows[qi]
              rj = rows[qj]

              # Different columns
              ci != cj and
                # Different diagonals
                abs(ci - cj) != abs(ri - rj)
            else
              true
            end
          end}
        end

      assert {:ok, solution} = AC3.solve(variables, constraints)

      cols = [solution.q1, solution.q2, solution.q3, solution.q4]

      # All columns are different
      assert length(Enum.uniq(cols)) == 4

      # No diagonal attacks
      for i <- 0..2, j <- (i + 1)..3 do
        assert abs(Enum.at(cols, i) - Enum.at(cols, j)) != abs(i - j),
               "Queens in rows #{i + 1} and #{j + 1} attack diagonally"
      end
    end

    test "3-Queens has no solution (impossible on 3×3 board)" do
      columns = Set.new([1, 2, 3])

      variables = %{
        q1: columns,
        q2: columns,
        q3: columns
      }

      queens = [:q1, :q2, :q3]
      rows = %{q1: 1, q2: 2, q3: 3}

      constraints =
        for qi <- queens,
            qj <- queens,
            qi < qj do
          {[qi, qj], fn assignment ->
            if Map.has_key?(assignment, qi) and Map.has_key?(assignment, qj) do
              ci = assignment[qi]
              cj = assignment[qj]
              ri = rows[qi]
              rj = rows[qj]

              ci != cj and abs(ci - cj) != abs(ri - rj)
            else
              true
            end
          end}
        end

      assert {:error, :no_solution} = AC3.solve(variables, constraints)
    end
  end

  # ============================================================================
  # Cross-phase integration: Network + JTMS for sensor fusion
  #
  # A practical scenario where a physical measurement system uses propagation
  # for derived values AND the JTMS for managing which sensor readings to trust.
  # Multiple temperature probes feed into a conversion pipeline; when probes
  # disagree, we can selectively retract untrusted readings and the entire
  # derived pipeline recomputes.
  # ============================================================================

  describe "sensor fusion pipeline (Network cross-phase)" do
    test "power dissipation: P = V²/R with sensor replacement" do
      # Power dissipated by a resistor: P = V * I, and V = I * R
      # So: P = I² * R = V² / R
      # We model: V = I * R, P = V * I
      {:ok, net} = Network.new()
      voltage = Network.create_cell(net)
      current = Network.create_cell(net)
      resistance = Network.create_cell(net)
      power = Network.create_cell(net)

      # V = I * R
      Arithmetic.multiplier(net, current, resistance, voltage)
      # P = V * I
      Arithmetic.multiplier(net, voltage, current, power)
      Process.sleep(@settle)

      # Measure: R = 100Ω, I = 0.5A
      Network.add_content(net, resistance, 100, :ohmmeter)
      Network.add_content(net, current, 0.5, :ammeter)
      Process.sleep(@settle)

      # V = 0.5 * 100 = 50V
      assert_in_delta Network.read_cell(net, voltage), 50.0, 0.01
      # P = 50 * 0.5 = 25W
      assert_in_delta Network.read_cell(net, power), 25.0, 0.01

      # Ammeter fails — replace with new reading
      Network.retract_content(net, current, :ammeter)
      Network.add_content(net, current, 0.3, :ammeter_v2)
      Process.sleep(@settle)

      # V = 0.3 * 100 = 30V
      assert_in_delta Network.read_cell(net, voltage), 30.0, 0.01
      # P = 30 * 0.3 = 9W
      assert_in_delta Network.read_cell(net, power), 9.0, 0.01
    end

    test "BMI calculator with retractable measurements" do
      # BMI = weight / height²
      # We model: height_sq = height * height, bmi * height_sq = weight
      {:ok, net} = Network.new()
      weight_kg = Network.create_cell(net)
      height_m = Network.create_cell(net)
      height_sq = Network.create_cell(net)
      bmi = Network.create_cell(net)

      # height_sq = height * height
      Arithmetic.multiplier(net, height_m, height_m, height_sq)
      # weight = bmi * height_sq → bmi = weight / height_sq
      Arithmetic.multiplier(net, bmi, height_sq, weight_kg)
      Process.sleep(@settle)

      Network.add_content(net, weight_kg, 70, :scale)
      Network.add_content(net, height_m, 1.75, :stadiometer)
      Process.sleep(@settle)

      # BMI = 70 / (1.75²) = 70 / 3.0625 ≈ 22.86
      assert_in_delta Network.read_cell(net, bmi), 22.857, 0.01

      # Patient was wearing shoes — correct height
      Network.retract_content(net, height_m, :stadiometer)
      Network.add_content(net, height_m, 1.72, :stadiometer_corrected)
      Process.sleep(@settle)

      # BMI = 70 / (1.72²) = 70 / 2.9584 ≈ 23.66
      assert_in_delta Network.read_cell(net, bmi), 23.661, 0.01
    end
  end
end
