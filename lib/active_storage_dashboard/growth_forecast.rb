# frozen_string_literal: true

module ActiveStorageDashboard
  # Analyses how total blob storage grows month over month and projects it forward.
  #
  # Two models are fitted to the cumulative storage of the most recent complete months:
  # - linear:      total = a + b * t          (a steady amount is added every month)
  # - exponential: total = a * e^(r * t)      (storage grows by a steady percentage)
  #
  # Whichever explains the history better (R² in bytes, not log-space) becomes the
  # headline projection, and the trend of the monthly additions decides the verdict.
  class GrowthForecast
    FIT_WINDOW = 24 # months used to fit the models
    FORECAST_MONTHS = 12
    MIN_MONTHS = 3
    # Change of monthly additions across the fit window, relative to their mean,
    # beyond which growth counts as accelerating / slowing.
    TREND_THRESHOLD = 0.5

    def self.from_database(today: Date.current)
      new(monthly_bytes: monthly_bytes_from_database, today: today)
    end

    def self.monthly_bytes_from_database
      adapter = ActiveStorage::Blob.connection.adapter_name.downcase
      month = if adapter.include?('sqlite')
                "strftime('%Y-%m', created_at)"
              elsif adapter.include?('mysql') || adapter.include?('trilogy')
                "DATE_FORMAT(created_at, '%Y-%m')"
              else
                "TO_CHAR(created_at, 'YYYY-MM')"
              end

      ActiveStorage::Blob.group(Arel.sql(month)).sum(:byte_size).each_with_object({}) do |(key, bytes), result|
        next if key.blank?

        year, mon = key.to_s.split('-').map(&:to_i)
        result[Date.new(year, mon, 1)] = bytes.to_i
      end
    end

    attr_reader :months, :today

    # monthly_bytes: { Date (first of month) => bytes uploaded in that month }
    def initialize(monthly_bytes:, today: Date.current)
      @today = today
      @months = build_months(monthly_bytes)
    end

    def enough_data?
      complete_months.size >= MIN_MONTHS && complete_months.last[:total].positive?
    end

    def linear
      @linear ||= fit_linear(fit_points)
    end

    def exponential
      @exponential ||= fit_exponential(fit_points)
    end

    def best_model
      return :linear if exponential.nil?

      exponential[:r2] > linear[:r2] ? :exponential : :linear
    end

    # :accelerating, :exponential, :linear or :slowing
    def pattern
      trend = additions_trend
      if trend > TREND_THRESHOLD
        best_model == :exponential ? :exponential : :accelerating
      elsif trend < -TREND_THRESHOLD
        :slowing
      else
        :linear
      end
    end

    # Relative change of the monthly additions across the fit window (0 = constant).
    def additions_trend
      additions = fit_months.map { |m| m[:added].to_f }
      mean = additions.sum / additions.size
      return 0.0 if mean.zero?

      slope = fit_linear(additions.each_with_index.map { |y, i| [i, y] })[:slope]
      slope * (additions.size - 1) / mean
    end

    def average_monthly_addition(last: 6)
      recent = complete_months.last(last)
      recent.sum { |m| m[:added] } / recent.size
    end

    # Recent monthly additions relative to the current total, independent of any model.
    def monthly_growth_rate
      total = complete_months.last[:total]
      total.positive? ? average_monthly_addition.to_f / total : nil
    end

    # Months until the current total doubles according to the best-fitting model.
    def doubling_months
      if best_model == :exponential
        exponential[:rate].positive? ? Math.log(2) / exponential[:rate] : nil
      else
        linear[:slope].positive? ? current_total / linear[:slope] : nil
      end
    end

    def current_total
      months.last[:total]
    end

    # Projected total FORECAST_MONTHS after the last complete month.
    def projected_total(model = best_model)
      forecast(model).last&.dig(:total)
    end

    # Projection for the months after the last complete month, starting at that month
    # so the dashed line connects to the actual one.
    def forecast(model)
      fit = model == :exponential ? exponential : linear
      return [] unless fit

      origin = fit_months.size - 1
      (0..FORECAST_MONTHS).map do |step|
        t = origin + step
        total = if model == :exponential
                  Math.exp(fit[:intercept] + (fit[:rate] * t))
                else
                  fit[:intercept] + (fit[:slope] * t)
                end
        { month: complete_months.last[:month] >> step, total: [total, 0].max.round }
      end
    end

    def as_json(*)
      {
        months: months.map { |m| m.merge(month: m[:month].strftime('%Y-%m')) },
        forecasts: {
          linear: forecast(:linear).map { |p| p.merge(month: p[:month].strftime('%Y-%m')) },
          exponential: forecast(:exponential).map { |p| p.merge(month: p[:month].strftime('%Y-%m')) }
        },
        best_model: best_model,
        fit_start: fit_months.first[:month].strftime('%Y-%m')
      }
    end

    def fit_months
      complete_months.last(FIT_WINDOW)
    end

    def complete_months
      @complete_months ||= months.reject { |m| m[:partial] }
    end

    private

    def fit_points
      fit_months.each_with_index.map { |m, i| [i, m[:total].to_f] }
    end

    # Every month from the first upload until today, gaps filled with 0.
    def build_months(monthly_bytes)
      return [] if monthly_bytes.empty?

      current = today.beginning_of_month
      month = monthly_bytes.keys.min
      total = 0
      result = []
      while month <= current
        added = monthly_bytes.fetch(month, 0)
        total += added
        result << { month: month, added: added, total: total, partial: month == current }
        month = month.next_month
      end
      result
    end

    # Ordinary (or weighted) least squares on [x, y] points.
    def fit_linear(points, weights = nil)
      weights ||= Array.new(points.size, 1.0)
      w_sum = weights.sum.to_f
      mean_x = points.each_with_index.sum { |(x, _), i| weights[i] * x } / w_sum
      mean_y = points.each_with_index.sum { |(_, y), i| weights[i] * y } / w_sum
      sxx = points.each_with_index.sum { |(x, _), i| weights[i] * ((x - mean_x)**2) }
      sxy = points.each_with_index.sum { |(x, y), i| weights[i] * (x - mean_x) * (y - mean_y) }
      slope = sxx.zero? ? 0.0 : sxy / sxx
      intercept = mean_y - (slope * mean_x)
      { slope: slope, intercept: intercept, r2: r_squared(points) { |x| intercept + (slope * x) } }
    end

    # Least squares on ln(total), weighted by total² so small early months don't dominate the fit
    # (approximates least squares in bytes). R² is measured on the original scale so both models compare fairly.
    def fit_exponential(points)
      return nil if points.any? { |_, y| y <= 0 }

      log_fit = fit_linear(points.map { |x, y| [x, Math.log(y)] }, points.map { |_, y| y**2 })
      rate = log_fit[:slope]
      intercept = log_fit[:intercept]
      { rate: rate, intercept: intercept, r2: r_squared(points) { |x| Math.exp(intercept + (rate * x)) } }
    end

    def r_squared(points)
      mean = points.sum(&:last) / points.size
      ss_tot = points.sum { |_, y| (y - mean)**2 }
      return 1.0 if ss_tot.zero?

      ss_res = points.sum { |x, y| (y - yield(x))**2 }
      1 - (ss_res / ss_tot)
    end
  end
end
