defmodule HomeAgent.Propagator.TimePeriod do
  @moduledoc """
  Pure functions for mapping wall-clock time to named time periods and
  to a circadian lighting curve.

  Time periods (Winter's krici/belief directives apply here):

    "night"     — 00:00–05:59
    "morning"   — 06:00–08:59
    "daytime"   — 09:00–15:59
    "afternoon" — 16:00–17:59
    "evening"   — 18:00–21:59
    "pre_sleep" — 22:00–23:59
  """

  @periods [
    {{0, 0}, {5, 59}, "night"},
    {{6, 0}, {8, 59}, "morning"},
    {{9, 0}, {15, 59}, "daytime"},
    {{16, 0}, {17, 59}, "afternoon"},
    {{18, 0}, {21, 59}, "evening"},
    {{22, 0}, {23, 59}, "pre_sleep"}
  ]

  # Circadian curve: list of {hour, minute, kelvin, max_brightness}
  # max_brightness is 0–255.
  @circadian_waypoints [
    {0, 0, 2000, 20},
    {6, 0, 2200, 30},
    {8, 0, 4000, 180},
    {12, 0, 6500, 255},
    {16, 0, 5000, 230},
    {18, 0, 3000, 200},
    {20, 0, 2700, 150},
    {22, 0, 2200, 80},
    {23, 30, 2000, 20}
  ]

  @doc "Return the current time period name."
  def current_period do
    period_for(DateTime.utc_now())
  end

  @doc "Return the time period name for a given DateTime."
  def period_for(%DateTime{} = dt) do
    h = dt.hour
    m = dt.minute

    Enum.find_value(@periods, "night", fn {{sh, sm}, {eh, em}, name} ->
      after_start = h > sh or (h == sh and m >= sm)
      before_end = h < eh or (h == eh and m <= em)
      if after_start and before_end, do: name
    end)
  end

  @doc """
  Interpolate the circadian lighting curve for the given DateTime.
  Returns `{kelvin, max_brightness}`.
  """
  def circadian_at(%DateTime{} = dt) do
    minutes = dt.hour * 60 + dt.minute
    waypoints = Enum.map(@circadian_waypoints, fn {h, m, k, b} -> {h * 60 + m, k, b} end)

    case find_segment(waypoints, minutes) do
      nil ->
        {elem(hd(waypoints), 1), elem(hd(waypoints), 2)}

      {t0, k0, b0, t1, k1, b1} ->
        frac = (minutes - t0) / (t1 - t0)
        kelvin = round(k0 + frac * (k1 - k0))
        brightness = round(b0 + frac * (b1 - b0))
        {kelvin, brightness}
    end
  end

  @doc "Return `{kelvin, max_brightness}` for right now."
  def circadian_now do
    circadian_at(DateTime.utc_now())
  end

  # --- Private ---

  defp find_segment(waypoints, minutes) do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [{t0, k0, b0}, {t1, k1, b1}] ->
      if minutes >= t0 and minutes < t1, do: {t0, k0, b0, t1, k1, b1}
    end)
  end
end
