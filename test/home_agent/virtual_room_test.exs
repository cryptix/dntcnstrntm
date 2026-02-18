defmodule HomeAgent.VirtualRoomTest do
  @moduledoc """
  Scenario tests using VirtualRoom.

  Each test simulates a distinct real-world sensor situation and verifies
  that the presence-fusion confidence and computed lighting command match
  expectations.  `VirtualRoom.print/1` is called after every trigger so you
  can see the full visual summary in the test output (`mix test -v`).

  ## How sensor absence works

  `VirtualRoom.new/1` starts with **no sensor entities** configured.
  `set_mmwave/2`, `set_pir/2`, `set_door/2` register the sensor *and* inject
  its state.  Sensors that are never set are treated as truly absent from the
  Bayesian model (nil → prior unchanged), which matches a real room that
  physically lacks that sensor type.
  """

  use HomeAgent.Case, async: false

  alias HomeAgent.Propagator.TimePeriod

  # ── High-confidence (djuno) ───────────────────────────────────────────────

  describe "high-confidence occupancy (djuno)" do
    test "mmWave alone → confidence ≥ 80, djuno, full circadian brightness" do
      # P(occ | mmwave=true, prior=0.5) = 0.95*0.5 / (0.95*0.5 + 0.05*0.5) = 0.95 → 95%
      room =
        VirtualRoom.new(unique("mmwave_only"))
        |> VirtualRoom.set_mmwave(true)
        |> VirtualRoom.trigger()
        |> VirtualRoom.print()

      {confidence, etype} = VirtualRoom.read_presence(room)

      assert confidence == 95
      assert etype == :djuno

      assert match?({:turn_on, _, _, 1}, VirtualRoom.last_command(room))
      {:turn_on, _k, brightness, 1} = VirtualRoom.last_command(room)
      {_k, max_brightness} = TimePeriod.circadian_now()
      assert brightness == max_brightness, "djuno: full circadian brightness expected"
    end

    test "mmWave + PIR → very high confidence (≥ 95%), djuno, full brightness" do
      # P(occ | mmwave=true, pir=true) → nearly certain
      room =
        VirtualRoom.new(unique("mmwave_pir"))
        |> VirtualRoom.set_mmwave(true)
        |> VirtualRoom.set_pir(true)
        |> VirtualRoom.trigger()
        |> VirtualRoom.print()

      {confidence, etype} = VirtualRoom.read_presence(room)

      assert confidence >= 95
      assert etype == :djuno
      assert match?({:turn_on, _, _, 1}, VirtualRoom.last_command(room))

      {:turn_on, _k, brightness, 1} = VirtualRoom.last_command(room)
      {_k, max_brightness} = TimePeriod.circadian_now()
      assert brightness == max_brightness
    end
  end

  # ── Moderate confidence (jinvi) ───────────────────────────────────────────

  describe "moderate confidence (jinvi)" do
    test "PIR-only room → 80% confidence, jinvi, 60% brightness at 1s" do
      # Room has NO mmWave sensor (not configured at all).
      # P(occ | pir=true, prior=0.5) = 0.80*0.5 / (0.80*0.5 + 0.20*0.5) = 0.80 → 80%
      # etype: score=80 but mmwave is nil (not true) → :jinvi
      room =
        VirtualRoom.new(unique("pir_only"))
        |> VirtualRoom.set_pir(true)
        |> VirtualRoom.trigger()
        |> VirtualRoom.print()

      {confidence, etype} = VirtualRoom.read_presence(room)

      assert confidence == 80
      assert etype == :jinvi

      assert match?({:turn_on, _, _, 1}, VirtualRoom.last_command(room)),
             "jinvi path: 1 s transition"

      {:turn_on, _k, brightness, 1} = VirtualRoom.last_command(room)
      {_k, max_brightness} = TimePeriod.circadian_now()

      assert brightness == round(max_brightness * 0.6),
             "jinvi path: 60% of max_brightness=#{max_brightness}"
    end
  end

  # ── Low confidence (krici) ────────────────────────────────────────────────

  describe "low confidence (krici)" do
    test "mmWave + PIR both off → confidence ≈ 1%, dim 30% lighting" do
      # Both sensors absent: strong negative evidence.
      # After mmwave=false: P ≈ 0.05;  after pir=false: P ≈ 0.013 → score=1%.
      # Bayesian posteriors never reach exactly 0 with these likelihoods,
      # so the system keeps a 30%-dim "someone might be home" fallback.
      room =
        VirtualRoom.new(unique("all_off"))
        |> VirtualRoom.set_mmwave(false)
        |> VirtualRoom.set_pir(false)
        |> VirtualRoom.trigger()
        |> VirtualRoom.print()

      {confidence, etype} = VirtualRoom.read_presence(room)

      assert confidence < 10
      assert etype == :krici

      assert match?({:turn_on, _, _, 2}, VirtualRoom.last_command(room)),
             "krici with confidence > 0: 30% brightness at 2 s transition"
    end

    test "room with no sensors at all → prior 50%, krici, 30% dim lighting" do
      # No set_* calls: PresenceFusion has no sensor entities in config so
      # all three sensor reads return nil → the posterior stays at the prior
      # (0.5) and is never updated → score=50.
      # 50 < @min_confidence (60) so this is treated as low-confidence.
      room =
        VirtualRoom.new(unique("no_sensors"))
        |> VirtualRoom.trigger()
        |> VirtualRoom.print()

      {confidence, etype} = VirtualRoom.read_presence(room)

      assert confidence == 50
      assert etype == :krici

      assert match?({:turn_on, _, _, 2}, VirtualRoom.last_command(room)),
             "prior-only confidence (50%) → 30% brightness at 2 s transition"
    end
  end

  # ── State transitions ─────────────────────────────────────────────────────

  describe "sensor state transitions" do
    test "mmWave detected then cleared: confidence drops, lighting dims" do
      name = unique("transition")

      # Phase 1: mmWave detected
      room1 =
        VirtualRoom.new(name)
        |> VirtualRoom.set_mmwave(true)
        |> VirtualRoom.trigger()

      VirtualRoom.print(room1)
      {c1, e1} = VirtualRoom.read_presence(room1)
      assert c1 == 95
      assert e1 == :djuno

      # Phase 2: mmWave clears
      room2 =
        room1
        |> VirtualRoom.set_mmwave(false)
        |> VirtualRoom.trigger()

      VirtualRoom.print(room2)
      {c2, _} = VirtualRoom.read_presence(room2)

      assert c2 < c1, "Confidence should drop when mmWave reports clear"

      [cmd1, cmd2] = VirtualRoom.commands(room2)

      IO.puts("  Phase 1 command: #{inspect(cmd1)}")
      IO.puts("  Phase 2 command: #{inspect(cmd2)}")

      assert match?({:turn_on, _, _, 1}, cmd1), "Phase 1: snap on"
      assert match?({:turn_on, _, _, 2}, cmd2), "Phase 2: slow dim"
    end

    test "PIR flicker: repeated detection events keep lights on" do
      name = unique("flicker")

      room =
        VirtualRoom.new(name)
        |> VirtualRoom.set_pir(true)
        |> VirtualRoom.trigger()

      room = VirtualRoom.set_pir(room, false) |> VirtualRoom.trigger()
      room = VirtualRoom.set_pir(room, true) |> VirtualRoom.trigger()

      VirtualRoom.print(room)

      cmds = VirtualRoom.commands(room)
      assert length(cmds) == 3

      # Each trigger re-fuses from latest StateStore state.
      # pir=true → 80%, jinvi; pir=false → 20%, krici; pir=true → 80%, jinvi.
      [c1, c2, c3] = cmds

      assert match?({:turn_on, _, _, 1}, c1), "pir=true → jinvi path"
      assert match?({:turn_on, _, _, 2}, c2), "pir=false → krici path (30% dim)"
      assert match?({:turn_on, _, _, 1}, c3), "pir=true again → jinvi path"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "vr_#{prefix}_#{:erlang.unique_integer([:positive])}"
end
