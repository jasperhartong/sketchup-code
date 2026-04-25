# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Orchestrates all preview pairs. Responsibilities:
    #   — Build the two shared frame catalogs (one BackFrame + one FrontFrame per
    #     Config) and feed them to every preview BedPair.
    #   — Drive rendering through the backend-agnostic SketchupUtils::PartRendering
    #     driver + a concrete Renderer (SketchUpRenderer by default).
    #   — Run the validator, stock / hardware reports, and baseline snapshot
    #     save, using a SketchUp-specific tail (so backends without an active
    #     model can skip those safely).
    class BedLayout
      def initialize(config = nil)
        @config = config || Config.new
      end

      # ── Render ────────────────────────────────────────────────────────────

      # @param renderer [Object, nil] any SketchupUtils::Renderer implementation.
      #   Defaults to a fresh SketchUpRenderer. Pass your own (e.g. an OBJ
      #   exporter, a test double) to produce non-SketchUp output.
      # @param model [Sketchup::Model, nil] only used by the default renderer,
      #   validator, and baseline save — optional otherwise.
      # @param save_baseline [Boolean] when true (default), writes a named-group
      #   geometry snapshot to +Config::GEOMETRY_BASELINE_JSON+. Refactor
      #   validators that compare the current render against the on-disk
      #   baseline set +false+ to avoid self-contaminating the comparison.
      def create(model = nil, renderer: nil, save_baseline: true)
        model ||= Sketchup.active_model if defined?(Sketchup)
        renderer ||= SketchupUtils::SketchUpRenderer.new(
          model, attr_dict: Config::ATTR_DICT,
                 debug_color: @config.debug_color
        )
        layer = renderer.ensure_layer(Config::LAYER_NAME)

        renderer.commit('Extendable bed: clear') { clear(model) }

        back_frame  = BackFrame.new(@config)
        front_frame = FrontFrame.new(@config)
        stock       = StockPlanner.new(@config)

        pairs_for(back_frame, front_frame).each do |pair|
          _render_pair(pair, renderer: renderer, layer: layer, stock: stock)
        end

        renderer.invalidate_view

        Validator.new(@config).validate(model) if model
        stock_label = format('(one bed = %s + %s) ——',
                             Config::GROUP_EXT_BACK, Config::GROUP_EXT_FRONT)
        stock.print_report(label:           "[EB stock] #{stock_label}")
        stock.print_hardware_report(label:  "[EB hardware] #{stock_label}")
        _render_cut_plan_3d(renderer, stock, layer) if model && @config.show_cut_plan_3d

        _save_geometry_baseline(model) if model && save_baseline
      end

      def clear(model = Sketchup.active_model)
        _exit_edit_context!(model)
        roots = model.entities
        # Step labels are standalone Text entities, not inside EB roots.
        _purge_step_annotations!(model, roots)
        _purge_named_recursive(roots, Config::PURGE_NESTED_PART_GROUP_NAMES, skip_ref: true)
        to_erase = roots.grep(Sketchup::Group).select do |g|
          Config::GROUP_NAME_RE.match?(g.name) ||
            Config::SINGLE_PAIR_ROOTS.include?(g.name) ||
            g.name == Config::GROUP_CUT_PLAN_3D
        end
        to_erase.each(&:erase!)
        model.definitions.purge_unused if @config.purge_unused_definitions
      end

      def validate(model = Sketchup.active_model)
        Validator.new(@config).validate(model)
      end

      # The ordered pair list, shared frames threaded through.
      def pairs_for(back_frame, front_frame)
        BedPairCatalog.construction_bed_pairs(@config, back_frame: back_frame, front_frame: front_frame) +
          BedPairCatalog.extension_degree_bed_pairs(@config, back_frame: back_frame, front_frame: front_frame)
      end

      private

      def _render_pair(pair, renderer:, layer:, stock:)
        op_label = "#{pair.back_name} + #{pair.front_name}"

        renderer.commit("Extendable bed: #{op_label}") do
          planner = pair.tally_stock ? stock : nil

          back_root = SketchupUtils::PartRendering.render_view(
            pair.back_view, parent: :root, renderer: renderer, layer: layer,
            attr_dict: Config::ATTR_DICT,
            cut_hosts: @config.hardware_cut_hosts,
            countersink_first: @config.hardware_countersink_first,
            through_hole: @config.hardware_through_hole,
            on_beam:  planner ? ->(b) { planner.record(b) } : nil,
            on_screw: planner ? ->(s) { planner.record_screw(s) } : nil,
            corner_radius_for_part: method(:_corner_radius_for_part),
            corner_axis_for_part: method(:_corner_axis_for_part)
          )
          front_root = SketchupUtils::PartRendering.render_view(
            pair.front_view, parent: :root, renderer: renderer, layer: layer,
            attr_dict: Config::ATTR_DICT,
            cut_hosts: @config.hardware_cut_hosts,
            countersink_first: @config.hardware_countersink_first,
            through_hole: @config.hardware_through_hole,
            on_beam:  planner ? ->(b) { planner.record(b) } : nil,
            on_screw: planner ? ->(s) { planner.record_screw(s) } : nil,
            corner_radius_for_part: method(:_corner_radius_for_part),
            corner_axis_for_part: method(:_corner_axis_for_part)
          )

          _place_root(renderer, back_root,  pair.offset_x, pair.pair_row_y,                    pair.upside_down)
          _place_root(renderer, front_root, pair.offset_x, pair.pair_row_y + pair.foot_world_y, pair.upside_down)

          renderer.paint_group(back_root,  Config::PREVIEW_RGB_BACK)
          renderer.paint_group(front_root, Config::PREVIEW_RGB_FRONT)

          renderer.paint_named_children(back_root,  pair.back_highlight_part_names,  Config::PREVIEW_RGB_ACTIVE)
          renderer.paint_named_children(front_root, pair.front_highlight_part_names, Config::PREVIEW_RGB_ACTIVE)
          renderer.hide_named_children(back_root,  pair.back_hidden_part_names,  hidden: true)
          renderer.hide_named_children(front_root, pair.front_hidden_part_names, hidden: true)

          renderer.debug_paint_axis_faces(back_root,  skip_name_re: Config::SCREW_NAME_RE)
          renderer.debug_paint_axis_faces(front_root, skip_name_re: Config::SCREW_NAME_RE)

          # Pillows into their respective roots.
          back_pillow_view  = pair.back_pillow_set.view(group_name: "#{pair.back_name}__pillows")
          front_pillow_view = pair.front_pillow_set.view(group_name: "#{pair.front_name}__pillows")
          _render_pillow_view_into(back_pillow_view,  back_root,  renderer: renderer, layer: layer)
          _render_pillow_view_into(front_pillow_view, front_root, renderer: renderer, layer: layer)
        end
      end

      # Pillows are rendered directly as child groups of the frame root (no
      # intermediate "__pillows" group — matches the pre-refactor SketchUp
      # outliner). We inline the PartRendering loop with parent = the frame
      # root so each pillow is a direct child.
      def _render_pillow_view_into(view, parent_group, renderer:, layer:)
        view.parts.each do |part|
          g = renderer.create_group(part.name, parent: parent_group, layer: layer)
          if part.note && !part.note.empty?
            renderer.set_group_attribute(g, Config::ATTR_DICT, 'note', part.note)
          end
          renderer.add_box(
            g, at: [0, 0, 0], size: [part.dx, part.dy, part.dz],
            corner_radius: _corner_radius_for_part(part),
            corner_axis: _corner_axis_for_part(part)
          )
          renderer.set_group_transform(g, SketchupUtils::Transform.translation([part.x, part.y, part.z]))
        end
      end

      def _corner_radius_for_part(part)
        return @config.pillow_box_corner_radius if part.is_a?(SketchupUtils::Parts::Pillow)
        return @config.plank_box_corner_radius if part.is_a?(SketchupUtils::Parts::Plank)
        return @config.beam_box_corner_radius if part.is_a?(SketchupUtils::Parts::Beam)

        0
      end

      def _corner_axis_for_part(part)
        return @config.pillow_box_corner_axis if part.is_a?(SketchupUtils::Parts::Pillow)
        return @config.plank_box_corner_axis if part.is_a?(SketchupUtils::Parts::Plank)
        return @config.beam_box_corner_axis if part.is_a?(SketchupUtils::Parts::Beam)

        :long
      end

      # Rotates 180° about +Y (preserves Y, flips +X / +Z) when +upside_down+,
      # then lifts in world +Z until min.z → 0. Otherwise a plain translation.
      def _place_root(renderer, root, world_x, world_y, upside_down)
        if upside_down
          base = SketchupUtils::Transform.translation([world_x, world_y, 0])
          flip = SketchupUtils::Transform.rotation_y_180
          renderer.set_group_transform(root, base * flip)
          lift_z = -renderer.group_min_z(root)
          renderer.set_group_transform(
            root,
            SketchupUtils::Transform.translation([0, 0, lift_z]) * base * flip
          )
        else
          renderer.set_group_transform(root, SketchupUtils::Transform.translation([world_x, world_y, 0]))
        end
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

      def _render_cut_plan_3d(renderer, stock, layer)
        result = stock.cut_plan_result
        return unless result[:ok]

        renderer.commit('Extendable bed: cut plan 3D') do
          root = renderer.create_group(Config::GROUP_CUT_PLAN_3D, parent: :root, layer: layer)
          bar_spacing_y = (@config.beam_wide + 20.mm)
          side_offset_cols = 8
          bar_x0 = side_offset_cols * (@config.outer_width + @config.pair_gap_x)
          bar_y0 = 0
          section_y = @config.beam_narrow
          section_z = @config.beam_wide
          stock_len = @config.stock_bar_length

          result[:bars].each_with_index do |bar, i|
            bar_group = renderer.create_group("bar #{i + 1}", parent: root, layer: layer)
            renderer.add_box(bar_group, at: [0, 0, 0], size: [stock_len, section_y, section_z])
            renderer.set_group_transform(
              bar_group,
              SketchupUtils::Transform.translation([bar_x0, bar_y0 + (i * bar_spacing_y), 0])
            )
            _paint_cut_plan_group(renderer, bar_group, [120, 120, 120])

            cursor_x = 0.0.mm
            bar[:parts].each do |part|
              part_group = renderer.create_group(part[:name], parent: bar_group, layer: layer)
              renderer.add_box(part_group, at: [0, 0, 0], size: [part[:mm].mm, section_y, section_z])
              renderer.set_group_transform(
                part_group,
                SketchupUtils::Transform.translation([cursor_x, 0, 0.1.mm])
              )
              _paint_cut_plan_group(renderer, part_group, _cut_plan_color_for_piece(part[:mm], section_y, section_z))
              cursor_x += part[:mm].mm + @config.stock_kerf_mm.mm
            end
          end
        end
      end

      def _paint_cut_plan_group(renderer, group, rgb)
        if renderer.respond_to?(:paint_group_force)
          renderer.paint_group_force(group, rgb)
        else
          renderer.paint_group(group, rgb)
        end
      end

      # Match component-reuse semantics: equal piece geometry => equal color.
      def _cut_plan_color_for_piece(length_mm, section_y, section_z)
        key = format(
          'EB::PartBox::%<x>.6f|%<y>.6f|%<z>.6f',
          x: section_y.to_f, y: length_mm.mm.to_f, z: section_z.to_f
        )
        seed = key.each_byte.reduce(0) { |acc, b| ((acc * 131) + b) & 0xFFFFFFFF }
        [120 + (seed & 0x7F), 120 + ((seed >> 7) & 0x7F), 120 + ((seed >> 14) & 0x7F)]
      end

      def _exit_edit_context!(model)
        while model.close_active; end
      end

      def _purge_named_recursive(entities, names, skip_ref: false)
        entities.to_a.each do |e|
          next unless e.valid?

          case e
          when Sketchup::Group
            next if skip_ref && Config::REFERENCE_ROOT_RE.match?(e.name)

            _purge_named_recursive(e.entities, names, skip_ref: skip_ref)
            e.erase! if names.include?(e.name)
          when Sketchup::ComponentInstance
            _purge_named_recursive(e.definition.entities, names, skip_ref: skip_ref)
            e.erase! if names.include?(e.name)
          end
        end
      end

      def _purge_step_annotations!(model, root_entities)
        ann_layer = model.layers[Config::STEP_ANNOTATIONS_LAYER]
        return unless ann_layer

        labels = root_entities.grep(Sketchup::Text).select { |t| t.layer == ann_layer }
        root_entities.erase_entities(labels) unless labels.empty?
      end
    end
  end
end
