# frozen_string_literal: true

# Standalone: GrowthForecast only needs ActiveSupport, so this runs without the dummy app.
#   ruby -Ilib test/growth_forecast_test.rb
require 'minitest/autorun'
require 'active_support/all'
require 'active_storage_dashboard/growth_forecast'

class GrowthForecastTest < Minitest::Test
  TODAY = Date.new(2026, 9, 24)

  # `months` complete months of uploads, ending with last month.
  def forecast_for(months: 32)
    start = TODAY.beginning_of_month << months
    monthly_bytes = (0...months).to_h { |i| [start >> i, yield(i).round] }
    ActiveStorageDashboard::GrowthForecast.new(monthly_bytes: monthly_bytes, today: TODAY)
  end

  # Monthly uploads that make the *total* follow the given curve.
  def forecast_for_total(months: 32, &total)
    forecast_for(months: months) { |i| total.call(i) - (i.zero? ? 0 : total.call(i - 1)) }
  end

  def test_constant_uploads_are_linear
    growth = forecast_for { 100_000_000 }

    assert_equal :linear, growth.pattern
    assert_equal :linear, growth.best_model
    assert_in_delta 1.0, growth.linear[:r2], 1e-9
    assert_equal growth.complete_months.last[:total] + 12 * 100_000_000, growth.projected_total
  end

  def test_compounding_uploads_are_exponential
    growth = forecast_for_total { |i| 100_000_000 * 1.08**i }

    assert_equal :exponential, growth.pattern
    assert_equal :exponential, growth.best_model
    assert_operator growth.exponential[:r2], :>, growth.linear[:r2]
    # Doubling time of 8% compound growth is ln(2) / ln(1.08) ≈ 9 months.
    assert_in_delta 9.0, growth.doubling_months, 0.5
  end

  def test_shrinking_uploads_are_slowing
    growth = forecast_for { |i| 300_000_000 - i * 9_000_000 }

    assert_equal :slowing, growth.pattern
  end

  # An early tiny month must not drag the exponential fit (unweighted log fits overshoot badly).
  def test_small_early_months_do_not_dominate_exponential_fit
    growth = forecast_for_total(months: 20) { |i| i.zero? ? 1_000 : 100_000_000 * 1.08**i }

    assert_in_delta Math.log(1.08), growth.exponential[:rate], 0.01
  end

  def test_current_month_is_excluded_from_fit_and_months_without_uploads_are_filled
    growth = ActiveStorageDashboard::GrowthForecast.new(
      monthly_bytes: {Date.new(2026, 5, 1) => 100, Date.new(2026, 7, 1) => 100, Date.new(2026, 9, 1) => 999},
      today: TODAY
    )

    assert_equal %w[2026-05 2026-06 2026-07 2026-08 2026-09], growth.months.map { |m| m[:month].strftime('%Y-%m') }
    assert_equal [0, 0, 0, 0, 999], growth.months.map { |m| m[:partial] ? m[:added] : 0 }
    assert_equal Date.new(2026, 8, 1), growth.fit_months.last[:month]
    assert_equal 1_199, growth.current_total
    assert growth.enough_data?
  end

  def test_needs_three_complete_months
    growth = ActiveStorageDashboard::GrowthForecast.new(
      monthly_bytes: {Date.new(2026, 8, 1) => 100, Date.new(2026, 9, 1) => 100},
      today: TODAY
    )

    refute growth.enough_data?
  end
end
