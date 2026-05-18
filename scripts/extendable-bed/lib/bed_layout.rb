# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Thin orchestrator: builds the DeclarationSet from Config + ExtendableBedSpec,
    # runs DeclarationsCompiler to produce SketchUp geometry, and handles the
    # surrounding infrastructure (stock report, validator, baseline snapshot).
    class BedLayout
      def initialize(config = nil)
        @config = config || Config.new
      end

      # Build all geometry and scenes in the active SketchUp model.
      def create(model = nil, save_baseline: true)
        model ||= Sketchup.active_model if defined?(Sketchup)
        c = @config

        renderer = SketchupUtils::SketchUpRenderer.new(
          model,
          attr_dict:   Config::ATTR_DICT,
          debug_color: c.debug_color
        )
        layer = renderer.ensure_layer(Config::LAYER_NAME)

        spec     = ExtendableBedSpec.build(c)
        compiler = SketchupUtils::DeclarationsCompiler.new(
          spec,
          renderer:    renderer,
          model:       model,
          layer:       layer,
          screw_specs: c.screw_specs,
          attr_dict:   Config::ATTR_DICT,
          cut_hosts:          c.hardware_cut_hosts,
          countersink_first:  c.hardware_countersink_first,
          through_hole:       c.hardware_through_hole,
          corner_radius_for_kind: {
            beam:   c.beam_box_corner_radius,
            plank:  c.plank_box_corner_radius,
            pillow: c.pillow_box_corner_radius
          },
          corner_axis_for_kind: {
            beam:   c.beam_box_corner_axis,
            plank:  c.plank_box_corner_axis,
            pillow: c.pillow_box_corner_axis
          },
          preview_rgb: Config::PREVIEW_RGB_BACK
        )

        # Purge old EB scenes first (before any geometry changes).
        renderer.finalize_scenes(prefix: 'EB | ', purge_all: false)
        renderer.commit('Extendable bed: clear') { compiler.clear }

        # Open extra scene scopes BEFORE compile so they land in SceneCapture.
        cut_plan_scope = renderer.scene('EB | Cut plan', camera: :top) if c.show_cut_plan_3d
        tap_scenes = {
          third_angle:     renderer.scene('EB | 3rd angle (retracted)', camera: :top),
          third_angle_ext: renderer.scene('EB | 3rd angle (extended)',  camera: :top)
        }

        stock = StockPlanner.new(c)
        compiler.compile
        _record_stock_from_spec(stock, spec)
        stock.print_report
        stock.print_hardware_report

        if c.show_cut_plan_3d
          cut_root = _render_cut_plan_3d(renderer, stock, layer, c)
          cut_plan_scope.track(cut_root) if cut_root
        end

        ThirdAngleProjection.create_scene(
          model, renderer,
          variant: ThirdAngleProjection.retracted_variant(c),
          row_y:   c.third_angle_row_y,
          layer:   layer,
          scenes:  tap_scenes
        )
        ThirdAngleProjection.create_scene(
          model, renderer,
          variant: ThirdAngleProjection.extended_variant(c),
          row_y:   c.third_angle_row_y - c.preview_row_step,
          layer:   layer,
          scenes:  tap_scenes
        )

        renderer.finalize_scenes(prefix: 'EB | ', purge_all: false)
        renderer.invalidate_view if model

        _save_geometry_baseline(model, spec.prefix) if model && save_baseline
      end

      # Erase all EB geometry from the model.
      def clear(model = nil)
        model ||= Sketchup.active_model if defined?(Sketchup)
        return unless model

        prefix = 'EB'
        while model.close_active; end
        to_erase = model.entities.select do |e|
          next false unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          e.name.start_with?(prefix) ||
            (e.is_a?(Sketchup::ComponentInstance) && e.definition.name.start_with?(prefix))
        end
        model.entities.erase_entities(to_erase) unless to_erase.empty?
        model.definitions.purge_unused
      end

      def validate(model = nil)
        model ||= Sketchup.active_model if defined?(Sketchup)
        Validator.new(@config).validate(model)
      end

      private

      # Walk the DeclarationSet and feed every leaf PartSpec into +stock+.
      # Composite groups (InstanceRef children) are skipped to avoid double-counting.
      BeamProxy  = Struct.new(:name, :size) do
        def extrusion_mm = size.map { |d| d.to_mm.abs }.max
      end
      PlankProxy = Struct.new(:dx, :dy, :dz)

      def _record_stock_from_spec(stock, decl_set)
        decl_set.components.each do |comp_spec|
          parts = comp_spec.children.select { |c| c.is_a?(SketchupUtils::Declarations::PartSpec) }
          next if parts.empty?

          parts.each do |ps|
            case ps.kind
            when :beam
              stock.record(BeamProxy.new(ps.id, ps.size))
            when :plank
              dx, dy, dz = ps.size
              stock.record_plank(PlankProxy.new(dx, dy, dz))
            end
          end
        end
      end

      def _render_cut_plan_3d(renderer, stock, layer, config)
        result = stock.cut_plan_result
        return nil unless result[:ok]

        root = nil
        renderer.commit('Extendable bed: cut plan 3D') do
          root = renderer.create_group('EB_CutPlan_3D', parent: :root, layer: layer)
          bar_spacing_y = config.beam_wide + 20.mm
          bar_y0        = config.cut_plan_row_y
          section_y     = config.beam_narrow
          section_z     = config.beam_wide
          stock_len     = config.stock_bar_length

          result[:bars].each_with_index do |bar, i|
            bar_group = renderer.create_group("bar #{i + 1}", parent: root, layer: layer)
            renderer.add_box(bar_group, at: [0, 0, 0], size: [stock_len, section_y, section_z])
            renderer.set_group_transform(
              bar_group,
              SketchupUtils::Transform.translation([0, bar_y0 + (i * bar_spacing_y), 0])
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
              _paint_cut_plan_group(renderer, part_group, _cut_plan_color(part[:mm], section_y, section_z))
              cursor_x += part[:mm].mm + config.stock_kerf_mm.mm
            end
          end
        end
        root
      end

      def _paint_cut_plan_group(renderer, group, rgb)
        if renderer.respond_to?(:paint_group_force)
          renderer.paint_group_force(group, rgb)
        else
          renderer.paint_group(group, rgb)
        end
      end

      def _cut_plan_color(length_mm, section_y, section_z)
        key  = format('EB::PartBox::%<x>.6f|%<y>.6f|%<z>.6f',
                      x: section_y.to_f, y: length_mm.mm.to_f, z: section_z.to_f)
        seed = key.each_byte.reduce(0) { |acc, b| ((acc * 131) + b) & 0xFFFFFFFF }
        [120 + (seed & 0x7F), 120 + ((seed >> 7) & 0x7F), 120 + ((seed >> 14) & 0x7F)]
      end

      def _save_geometry_baseline(model, prefix)
        snap_rb = File.expand_path('../../sketchup_utils/named_group_geometry_snapshot.rb', __dir__)
        load snap_rb unless defined?(Timmerman::SketchupUtils::NamedGroupGeometrySnapshot)

        root_filter = ->(e) { e.name.start_with?("#{prefix} | ") }
        Timmerman::SketchupUtils::NamedGroupGeometrySnapshot.save_snapshot(
          Config::GEOMETRY_BASELINE_JSON,
          model,
          root_filter: root_filter
        )
      end
    end
  end
end
