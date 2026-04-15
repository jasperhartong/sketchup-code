# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Orchestrates the side-by-side preview pairs, rendering each one into
    # SketchUp and wiring up the stock planner, validator, and dimensions.
    #
    # Only the full extended pair (EB_Ext_*) is counted in the stock/cut-list tally;
    # the other pairs are visual previews (extension 1 → 2 → 3, then retracted), plus
    # construction-step previews on a headward row (−Y).
    class BedLayout
      def initialize(config = nil)
        @config = config || Config.new
      end

      # ── Preview pairs ──────────────────────────────────────────────────────

      # Ordered list of pairs to build (see `BedPairCatalog` in construction_steps.rb):
      # seven construction-assembly previews, then five extension / retract previews.
      def pairs
        c = @config
        BedPairCatalog.construction_bed_pairs(c) + BedPairCatalog.extension_degree_bed_pairs(c)
      end

      # ── Main operations ────────────────────────────────────────────────────

      def create(model = Sketchup.active_model)
        model.start_operation('Extendable bed', true)
        clear(model)

        layer    = _ensure_layer(model)
        stock    = StockPlanner.new(@config)
        renderer = SketchUpRenderer.new(@config, model)

        pairs.each do |pair|
          planner = pair.tally_stock ? stock : nil

          # Back frame: placed at [offset_x, 0, 0] in world space.
          back_frame = pair.back_frame
          back_g     = renderer.render_frame(
            back_frame, model.entities,
            layer:        layer,
            stock_planner: planner,
            preview_rgb:  Config::PREVIEW_RGB_BACK
          )
          ry = pair.pair_row_y
          ox = pair.offset_x

          # Front frame: default [ox, ry + foot_world_y, 0]; same row logic as back.
          front_frame = pair.front_frame
          front_g     = renderer.render_frame(
            front_frame, model.entities,
            layer:         layer,
            stock_planner: planner,
            preview_rgb:   Config::PREVIEW_RGB_FRONT
          )

          if pair.upside_down
            _place_root_upside_down!(back_g, ox, ry)
            _place_root_upside_down!(front_g, ox, ry + pair.foot_world_y)
          else
            back_g.transformation = Geom::Transformation.translation([ox, ry, 0])
            front_g.transformation = Geom::Transformation.translation([ox, ry + pair.foot_world_y, 0])
          end

          renderer.repaint_named_children(back_g, pair.back_highlight_part_names,
                                          Config::PREVIEW_RGB_ACTIVE)
          renderer.repaint_named_children(front_g, pair.front_highlight_part_names,
                                          Config::PREVIEW_RGB_ACTIVE)

          # Pillows are added into their respective root groups.
          pillows = pair.pillows
          (pillows[:back]  || []).each { |p| renderer.add_part(back_g.entities,  p, layer: layer) }
          (pillows[:front] || []).each { |p| renderer.add_part(front_g.entities, p, layer: layer) }
        end

        model.commit_operation
        model.active_view.invalidate

        Validator.new(@config).validate(model)
        stock.print_report(
          label: format('[EB stock] (one bed = %s + %s) ——',
                        Config::GROUP_EXT_BACK, Config::GROUP_EXT_FRONT)
        )

        _save_geometry_baseline(model)
      end

      def clear(model = Sketchup.active_model)
        _exit_edit_context!(model)
        roots = model.entities
        _purge_named_recursive(roots, Config::PURGE_NESTED_PART_GROUP_NAMES, skip_ref: true)
        to_erase = roots.grep(Sketchup::Group).select do |g|
          Config::GROUP_NAME_RE.match?(g.name) || Config::SINGLE_PAIR_ROOTS.include?(g.name)
        end
        to_erase.each(&:erase!)
      end

      def validate(model = Sketchup.active_model)
        Validator.new(@config).validate(model)
      end

      private

      # Rotate 180° about bed length (+Y) so +Z points down while preserving local Y
      # (same back/front spacing as upright). About +X would flip Y and pull the
      # halves apart along the bed. Then lift in world +Z until min.z → 0.
      def _place_root_upside_down!(group, world_x, world_y)
        base = Geom::Transformation.translation([world_x, world_y, 0])
        flip = Geom::Transformation.rotation(
          Geom::Point3d.new(0, 0, 0),
          Geom::Vector3d.new(0, 1, 0),
          Math::PI
        )
        group.transformation = base * flip
        lift_z = -group.bounds.min.z
        group.transformation = Geom::Transformation.translation([0, 0, lift_z]) * group.transformation
      end

      def _save_geometry_baseline(model)
        snap_rb = File.expand_path('../../sketchup_utils/named_group_geometry_snapshot.rb', __dir__)
        load snap_rb unless defined?(Timmerman::SketchupUtils::NamedGroupGeometrySnapshot)

        root_filter = lambda do |g|
          Config::GROUP_NAME_RE.match?(g.name) || Config::SINGLE_PAIR_ROOTS.include?(g.name)
        end
        Timmerman::SketchupUtils::NamedGroupGeometrySnapshot.save_snapshot(
          Config::GEOMETRY_BASELINE_JSON,
          model,
          root_filter: root_filter
        )
      end

      def _ensure_layer(model)
        model.layers[Config::LAYER_NAME] || model.layers.add(Config::LAYER_NAME)
      end

      # Pops all nested edit contexts before erasing root groups.
      def _exit_edit_context!(model)
        while model.close_active; end
      end

      # Recursively erases groups whose name is in +names+ (exact match).
      # With +skip_ref: true+, skips subtrees rooted at Config::REFERENCE_ROOT_RE names.
      def _purge_named_recursive(entities, names, skip_ref: false)
        entities.to_a.each do |e|
          next unless e.valid? && e.is_a?(Sketchup::Group)
          next if skip_ref && Config::REFERENCE_ROOT_RE.match?(e.name)

          _purge_named_recursive(e.entities, names, skip_ref: skip_ref)
          e.erase! if names.include?(e.name)
        end
      end
    end
  end
end
