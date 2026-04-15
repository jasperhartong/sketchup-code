# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Translates an array of Part value objects (from a FrameAssembly) into real
    # SketchUp groups.  All geometry decisions live in the frame classes; this
    # class only knows about the SketchUp API.
    #
    # Usage:
    #   renderer = SketchUpRenderer.new(config, model)
    #   renderer.render_frame(frame, parent_entities, layer:, stock_planner:, preview_rgb:)
    class SketchUpRenderer
      def initialize(config, model)
        @config = config
        @model  = model
      end

      # Renders a complete FrameAssembly into +parent_entities+.
      # +stock_planner+ (optional) receives every Beam for the cut-list tally.
      # +preview_rgb+   (optional) [r,g,b] painted on all faces for shaded view.
      # Returns the SketchUp::Group that was created.
      def render_frame(frame, parent_entities, layer:, stock_planner: nil, preview_rgb: nil)
        root = parent_entities.add_group
        root.name  = frame.group_name
        root.layer = layer

        frame.parts.each do |part|
          add_part(root.entities, part, layer: layer)
          stock_planner.record(part) if stock_planner && part.is_a?(Beam)
        end

        paint_preview(root, preview_rgb) if preview_rgb
        root
      end

      # Re-paints direct child groups whose names match +names+ (Outliner part names).
      def repaint_named_children(root, names, rgb)
        return if names.nil? || names.empty?

        mat = _ensure_material(rgb)
        Array(names).each do |name|
          g = root.entities.grep(Sketchup::Group).find { |child| child.name == name }
          _paint_recursive(g.entities, mat) if g
        end
      end

      # Renders a single Part into the given entities without wrapping in a root.
      # Used by BedPair to add pillows directly to an existing root group.
      def add_part(entities, part, layer: nil)
        g       = entities.add_group
        g.name  = part.name
        g.layer = layer if layer
        g.set_attribute(Config::ATTR_DICT, 'note', part.note) if part.note && !part.note.empty?
        _add_box(g.entities, 0, 0, 0, part.dx, part.dy, part.dz)
        g.transformation = Geom::Transformation.translation([part.x, part.y, part.z])
        g
      end

      private

      # ── Box geometry ─────────────────────────────────────────────────────────

      # Pushes a rectangular solid into +entities+ with one corner at the origin.
      def _add_box(entities, x, y, z, dx, dy, dz)
        pts = [
          Geom::Point3d.new(x,      y,      z),
          Geom::Point3d.new(x + dx, y,      z),
          Geom::Point3d.new(x + dx, y + dy, z),
          Geom::Point3d.new(x,      y + dy, z)
        ]
        f = entities.add_face(pts)
        f.reverse! if f.normal.z < 0
        f.pushpull(dz)
      end

      # ── Preview materials ─────────────────────────────────────────────────────

      def paint_preview(group, rgb)
        mat = _ensure_material(rgb)
        _paint_recursive(group.entities, mat)
      end

      def _ensure_material(rgb)
        name = "EB preview | #{rgb.join(',')}"
        m    = @model.materials[name] || @model.materials.add(name)
        m.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
        m
      end

      def _paint_recursive(entities, material)
        entities.each do |e|
          case e
          when Sketchup::Face
            e.material      = material
            e.back_material = material
          when Sketchup::Group
            _paint_recursive(e.entities, material)
          when Sketchup::ComponentInstance
            _paint_recursive(e.definition.entities, material)
          end
        end
      end
    end
  end
end
