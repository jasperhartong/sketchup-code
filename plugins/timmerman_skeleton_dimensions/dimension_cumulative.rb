# encoding: utf-8
# dimension_cumulative.rb — emit horizontal cumulative dimensions from origin.
# Loaded by core.rb; methods added to Timmerman::SkeletonDimensions.

module Timmerman
  module SkeletonDimensions
    def emit_cumulative_dims(entities, unique_x_pairs, origin_x, gap_fn, stagger_dir,
                             make_base_pt:, make_h_anchor:, nudge:, sublayer: nil, max_count: nil)
      dim_i = 0
      count = 0
      unique_x_pairs.each do |x, far_h_pt|
        break if max_count && count >= max_count
        next if (x - origin_x).abs < MIN_DIMENSION_GAP
        base_pt = make_base_pt.call(far_h_pt)
        far_pt  = make_h_anchor.call(base_pt, x)
        d       = gap_fn.call(far_h_pt) + OUTER_PADDING + dim_i * STAGGER_STEP
        off     = scale_vec(stagger_dir, d)
        align_dim(
          entities.add_dimension_linear(nudge.call(base_pt), nudge.call(far_pt), off),
          sublayer
        )
        count += 1
        dim_i  += 1
      end
      count
    end
  end
end
