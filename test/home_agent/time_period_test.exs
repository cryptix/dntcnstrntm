defmodule HomeAgent.Propagator.TimePeriodTest do
  use ExUnit.Case, async: true

  alias HomeAgent.Propagator.TimePeriod

  defp dt(hour, minute \\ 0) do
    %DateTime{
      year: 2026, month: 1, day: 15,
      hour: hour, minute: minute, second: 0,
      time_zone: "Etc/UTC", zone_abbr: "UTC",
      utc_offset: 0, std_offset: 0
    }
  end

  describe "period_for/1" do
    test "midnight is night" do
      assert TimePeriod.period_for(dt(0)) == "night"
    end

    test "3am is night" do
      assert TimePeriod.period_for(dt(3)) == "night"
    end

    test "5:59am is night" do
      assert TimePeriod.period_for(dt(5, 59)) == "night"
    end

    test "6am is morning" do
      assert TimePeriod.period_for(dt(6)) == "morning"
    end

    test "8:59am is morning" do
      assert TimePeriod.period_for(dt(8, 59)) == "morning"
    end

    test "9am is daytime" do
      assert TimePeriod.period_for(dt(9)) == "daytime"
    end

    test "noon is daytime" do
      assert TimePeriod.period_for(dt(12)) == "daytime"
    end

    test "4pm is afternoon" do
      assert TimePeriod.period_for(dt(16)) == "afternoon"
    end

    test "6pm is evening" do
      assert TimePeriod.period_for(dt(18)) == "evening"
    end

    test "10pm is pre_sleep" do
      assert TimePeriod.period_for(dt(22)) == "pre_sleep"
    end

    test "11:59pm is pre_sleep" do
      assert TimePeriod.period_for(dt(23, 59)) == "pre_sleep"
    end
  end

  describe "circadian_at/1" do
    test "noon is coolest and brightest" do
      {kelvin, brightness} = TimePeriod.circadian_at(dt(12))
      assert kelvin == 6500
      assert brightness == 255
    end

    test "midnight is warmest and dimmest" do
      {kelvin, brightness} = TimePeriod.circadian_at(dt(0))
      assert kelvin == 2000
      assert brightness == 20
    end

    test "9am is between morning and noon (interpolated)" do
      {kelvin, _brightness} = TimePeriod.circadian_at(dt(9))
      # Should be between 4000 (8am) and 6500 (noon)
      assert kelvin > 4000
      assert kelvin < 6500
    end

    test "interpolated brightness is between waypoints" do
      {_k, b_6} = TimePeriod.circadian_at(dt(6))
      {_k, b_8} = TimePeriod.circadian_at(dt(8))
      {_k, b_7} = TimePeriod.circadian_at(dt(7))

      assert b_7 > b_6
      assert b_7 < b_8
    end

    test "returns integers" do
      {k, b} = TimePeriod.circadian_at(dt(14, 30))
      assert is_integer(k)
      assert is_integer(b)
    end
  end
end
