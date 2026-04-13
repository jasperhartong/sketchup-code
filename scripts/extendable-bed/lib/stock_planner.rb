# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Tracks 44×69 stock usage and produces a cut plan that fits pieces into
    # standard-length bars using First-Fit Decreasing (FFD) and Best-Fit
    # Decreasing (BFD), each with an optional single-cut local-improvement pass.
    # The best result (fewest bars, then least total waste) is kept.
    #
    # Usage:
    #   planner = StockPlanner.new(config)
    #   planner.record(beam_part)     # called by SketchUpRenderer for every Beam
    #   planner.print_report
    class StockPlanner
      attr_reader :total_extrusion_m, :piece_count, :cuts

      def initialize(config)
        @config          = config
        @total_extrusion_m = 0.0
        @piece_count     = 0
        @cuts            = []   # [{ name:, mm: }, ...]
        @active          = true
      end

      # Pause/resume tallying (extra preview pairs are not counted).
      def pause!  = (@active = false)
      def resume! = (@active = true)
      def active? = @active

      # Register a Beam part.  Only called when active.
      def record(beam)
        return unless @active

        mm = beam.extrusion_mm.to_f
        @total_extrusion_m += mm / 1000.0
        @piece_count       += 1
        @cuts              << { name: beam.name, mm: mm }
      end

      # Returns the cut-plan hash (see #pack) and prints a human-readable report.
      def print_report(label: '[EB stock]')
        stock_mm = @config.stock_bar_length.to_mm
        kerf     = @config.stock_kerf_mm.to_f

        result = pack(@cuts, stock_mm, kerf_mm: kerf)

        unless result[:ok]
          puts "#{label} Cut plan: some pieces are longer than one stock bar " \
               "(#{stock_mm.round(1)} mm) — increase stock_bar_length or shorten cuts:"
          result[:oversize].each { |c| puts format('  %s — %.1f mm', c[:name], c[:mm]) }
          return result
        end

        bars        = result[:bars]
        total_waste = bars.sum { |b| b[:waste_mm] }
        sum_cuts    = @cuts.sum { |c| c[:mm] }
        puts format(
          '%s %.3f m extrusion, %d pieces. ' \
          'Cut plan: %d bar(s) for %d cut(s); ' \
          'combined offcuts %.1f mm (%.3f m). (best of FFD/BFD + local moves)',
          label, @total_extrusion_m, @piece_count,
          bars.size, @cuts.size, total_waste, total_waste / 1000.0
        )
        puts "  Kerf between cuts on the same bar is included (#{kerf} mm)." if kerf > 0

        bars.each_with_index do |bar, i|
          puts format('  Bar %d: used %.1f mm, offcut %.1f mm', i + 1, bar[:used_mm], bar[:waste_mm])
          bar[:parts].each { |p| puts format('    — %.1f mm  %s', p[:mm], p[:name]) }
        end

        result
      end

      # ── Bin-packing ────────────────────────────────────────────────────────

      # Returns { ok: true, bars: [{used_mm:, waste_mm:, parts: [{name:, mm:}]}] }
      # or      { ok: false, oversize: [{name:, mm:}] }
      def pack(cuts, stock_mm, kerf_mm: 0.0)
        tol      = Config::SECTION_TOL_MM
        list     = cuts.map { |c| { name: c[:name], mm: c[:mm].to_f } }
        oversize = list.select { |c| c[:mm] > stock_mm + tol }
        return { ok: false, oversize: oversize } unless oversize.empty?

        kerf  = kerf_mm.to_f
        seeds = [
          _ffd(list.map(&:dup), stock_mm, kerf, tol),
          _bfd(list.map(&:dup), stock_mm, kerf, tol)
        ]

        best_bins  = nil
        best_score = nil
        seeds.each do |raw|
          [false, true].each do |improve|
            b  = _deep_dup(raw)
            _improve!(b, stock_mm, kerf, tol) if improve
            sc = _score(b, stock_mm, kerf)
            if best_score.nil? || _better?(sc, best_score)
              best_score = sc
              best_bins  = b
            end
          end
        end

        { ok: true, bars: _finalize(best_bins, stock_mm, kerf) }
      end

      private

      # ── Helpers ──────────────────────────────────────────────────────────────

      def _bar_used(parts, kerf)
        return 0.0 if parts.nil? || parts.empty?

        parts.sum { |p| p[:mm] } + (parts.size > 1 ? kerf * (parts.size - 1) : 0.0)
      end

      def _score(bins, stock_mm, kerf)
        waste = bins.sum { |b| stock_mm - _bar_used(b[:parts], kerf) }
        [bins.size, waste]
      end

      def _better?(candidate, than)
        c0, c1 = candidate
        t0, t1 = than
        c0 < t0 || (c0 == t0 && c1 < t1)
      end

      def _deep_dup(bins)
        bins.map { |b| { parts: b[:parts].map { |p| { name: p[:name], mm: p[:mm] } } } }
      end

      # First-Fit Decreasing
      def _ffd(list, stock_mm, kerf, tol)
        bins = []
        list.sort_by! { |c| [-c[:mm], c[:name].to_s] }
        list.each do |cut|
          placed = bins.any? do |bar|
            trial = bar[:parts] + [cut]
            next false if _bar_used(trial, kerf) > stock_mm + tol

            bar[:parts] << cut
            true
          end
          bins << { parts: [cut] } unless placed
        end
        bins
      end

      # Best-Fit Decreasing (tightest slack first)
      def _bfd(list, stock_mm, kerf, tol)
        bins = []
        list.sort_by! { |c| [-c[:mm], c[:name].to_s] }
        list.each do |cut|
          best_bar   = nil
          best_slack = nil
          bins.each do |bar|
            trial = bar[:parts] + [cut]
            u     = _bar_used(trial, kerf)
            next if u > stock_mm + tol

            slack = stock_mm - u
            if best_slack.nil? || slack < best_slack
              best_slack = slack
              best_bar   = bar
            end
          end
          best_bar ? (best_bar[:parts] << cut) : (bins << { parts: [cut] })
        end
        bins
      end

      # Greedy single-cut relocation: move one cut to another bar if it improves the score.
      def _improve!(bins, stock_mm, kerf, tol)
        loop do
          baseline     = _score(bins, stock_mm, kerf)
          best_cand    = nil
          best_score   = baseline

          bins.size.times do |i|
            bins.size.times do |j|
              next if i == j

              bins[i][:parts].each_index do |pi|
                trial = _deep_dup(bins)
                p     = trial[i][:parts].delete_at(pi)
                next if p.nil?

                trial[j][:parts] << p
                trial.reject! { |b| b[:parts].empty? }
                next if trial.any? { |b| _bar_used(b[:parts], kerf) > stock_mm + tol }

                sc = _score(trial, stock_mm, kerf)
                if _better?(sc, best_score)
                  best_score = sc
                  best_cand  = trial
                end
              end
            end
          end

          break if best_cand.nil?

          bins.replace(best_cand)
        end
        bins
      end

      def _finalize(bins, stock_mm, kerf)
        bins.map do |bar|
          u = _bar_used(bar[:parts], kerf)
          { used_mm: u, waste_mm: stock_mm - u, parts: bar[:parts].map(&:dup) }
        end
      end
    end
  end
end
