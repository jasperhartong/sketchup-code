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
    #   planner.record_screw(placement)  # same tally scope — only when planner is passed in
    #   planner.print_report
    #   planner.print_hardware_report
    class StockPlanner
      attr_reader :total_extrusion_m, :total_surface_m2, :piece_count, :cuts, :screw_counts

      def initialize(config)
        @config          = config
        @total_extrusion_m = 0.0
        @total_surface_m2  = 0.0  # all 6 faces per beam (ends included) — for finishing/sanding budget
        @piece_count     = 0
        @cuts            = []   # [{ name:, mm: }, ...]
        @screw_counts    = Hash.new(0) # [[spec_id, shaft_length_index], count]
        @specs_by_id     = {}          # remembered from placements (decouples from Config)
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
        s1, s2 = _section_sides_mm(beam, mm)
        # All 6 faces of the rectangular prism: 4 long sides + 2 ends.
        surface_mm2 = (2.0 * mm * (s1 + s2)) + (2.0 * s1 * s2)

        @total_extrusion_m += mm / 1000.0
        @total_surface_m2  += surface_mm2 / 1_000_000.0
        @piece_count       += 1
        @cuts              << { name: beam.name, mm: mm }
      end

      # Returns the two cross-section side lengths in mm by removing the dim
      # that matches +ext_mm+ (extrusion length) from +beam.size+.
      def _section_sides_mm(beam, ext_mm)
        size_mm = beam.size.map { |d| d.to_mm.abs }
        i = size_mm.find_index { |d| (d - ext_mm).abs < SketchupUtils::Parts::Beam::SECTION_TOL_MM }
        size_mm.delete_at(i) if i
        size_mm
      end

      # Register one screw placement (same +@active+ / tally scope as #record).
      # Remembers +placement.spec+ so the hardware report doesn't need +Config+.
      def record_screw(placement)
        return unless @active

        key = [placement.spec_id, placement.shaft_length_index]
        @screw_counts[key] += 1
        @specs_by_id[placement.spec_id] ||= placement.spec
      end

      # Prints screw BOM lines for the tallied pair (after #print_report is fine).
      def print_hardware_report(label: '[EB hardware]')
        total = @screw_counts.values.sum
        return if total.zero?

        puts label
        @screw_counts.sort_by { |(spec_id, idx), _| [spec_id.to_s, idx] }.each do |(spec_id, idx), n|
          spec = @specs_by_id[spec_id] ||
                 raise(KeyError, "unknown screw spec #{spec_id.inspect} (no placement was recorded)")
          mm   = spec.shaft_length_at(idx).to_mm.round(1)
          dia  = spec.shaft_diameter.to_mm.round(1)
          puts format('  %d × %s  Ø%.1f mm  shaft %.1f mm', n, spec_id, dia, mm)
        end
        puts format('  Total %d screw instances (same one-bed scope as stock above).', total)
      end

      # Returns the cut-plan hash (see #pack) and prints a human-readable report.
      def print_report(label: '[EB stock]')
        stock_mm = @config.stock_bar_length.to_mm
        kerf     = @config.stock_kerf_mm.to_f
        result   = cut_plan_result

        unless result[:ok]
          puts "#{label} Cut plan: some pieces are longer than one stock bar " \
               "(#{stock_mm.round(1)} mm) — increase stock_bar_length or shorten cuts:"
          result[:oversize].each { |c| puts format('  %s — %.1f mm', c[:name], c[:mm]) }
          return result
        end

        bars        = result[:bars]
        total_waste = bars.sum { |b| b[:waste_mm] }
        puts format(
          '%s %.3f m extrusion, %d pieces. ' \
          'Cut plan: %d bar(s) for %d cut(s); ' \
          'combined offcuts %.1f mm (%.3f m). (best of FFD/BFD + local moves)',
          label, @total_extrusion_m, @piece_count,
          bars.size, @cuts.size, total_waste, total_waste / 1000.0
        )
        puts format(
          '  Raw wood surface (onbewerkt): %.3f m² — all 6 faces per piece (4 long sides + 2 ends).',
          @total_surface_m2
        )
        puts "  Kerf between cuts on the same bar is included (#{kerf} mm)." if kerf > 0

        bars.each_with_index do |bar, i|
          puts format('  Bar %d: used %.1f mm, offcut %.1f mm', i + 1, bar[:used_mm], bar[:waste_mm])
          bar[:parts].each { |p| puts format('    — %.1f mm  %s', p[:mm], p[:name]) }
        end

        result
      end

      def cut_plan_result
        stock_mm = @config.stock_bar_length.to_mm
        kerf     = @config.stock_kerf_mm.to_f
        pack(@cuts, stock_mm, kerf_mm: kerf)
      end

      # ── Bin-packing ────────────────────────────────────────────────────────

      # Returns { ok: true, bars: [{used_mm:, waste_mm:, parts: [{name:, mm:}]}] }
      # or      { ok: false, oversize: [{name:, mm:}] }
      def pack(cuts, stock_mm, kerf_mm: 0.0)
        tol      = SketchupUtils::Parts::Beam::SECTION_TOL_MM
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
