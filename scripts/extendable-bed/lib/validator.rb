# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Checks that no two leaf parts within any EB component definition have
    # overlapping axis-aligned bounding boxes. Screws are excluded.
    #
    # Touching faces (coincident surfaces) are allowed; only true volumetric
    # overlap is flagged.
    #
    # NEVER add exceptions, allowlists, or "intentional overlap" skips.
    # If the validator reports an overlap, fix the geometry — do not weaken
    # the check.
    #
    # Usage:
    #   Validator.new.validate(model)            # prints + returns pairs
    #   Validator.new.overlapping_pairs(model)   # just returns pairs
    class Validator
      MARKER_NAME   = 'EB_overlap_marker'
      MARKER_PAD    = 10.mm
      MARKER_ALPHA  = 0.85

      def initialize(_config = nil); end

      # Prints a summary; returns the overlap list (empty = OK).
      # When +highlight+ is true, a semi-transparent box is drawn at the
      # intersection AABB of each overlapping pair (+ padding).
      def validate(model = Sketchup.active_model, highlight: false)
        pairs = overlapping_pairs(model)
        if pairs.empty?
          puts '[EB validate] OK — no part bounding-box overlaps.'
        else
          puts "[EB validate] FAIL — #{pairs.size} overlapping part pair(s):"
          pairs.each { |p| puts _format_overlap_line(p) }
          _draw_overlap_markers(model, pairs) if highlight
        end
        pairs
      end

      # Returns an array of hashes per overlapping pair:
      #   :definition, :part_a, :part_b, :bb_a, :bb_b
      def overlapping_pairs(model = Sketchup.active_model)
        pairs = []
        _eb_definitions(model).each do |defn|
          items = []
          _collect_parts(defn.entities, Geom::Transformation.new, items)

          (0...items.size).each do |i|
            ((i + 1)...items.size).each do |j|
              a = items[i]
              b = items[j]
              next if a[:eid] == b[:eid]
              next unless _aabb_overlap?(a[:bb], b[:bb])

              pairs << {
                definition: defn.name,
                part_a:     a[:name],
                part_b:     b[:name],
                bb_a:       a[:bb],
                bb_b:       b[:bb]
              }
            end
          end
        end
        pairs
      end

      private

      def _format_overlap_line(p)
        "  [#{p[:definition]}]  #{p[:part_a]}  ⟷  #{p[:part_b]}"
      end

      # ── Overlap marker geometry ──────────────────────────────────────────────

      # For each overlapping pair, draw a semi-transparent magenta box at the
      # intersection AABB (+ MARKER_PAD) directly inside the component definition.
      # The box shows up in every scene placement of that composite automatically.
      # Deduplicated so one unique intersection only ever gets one marker.
      def _draw_overlap_markers(model, pairs)
        mat   = _ensure_marker_material(model)
        drawn = {}   # definition_name => [intersection_key, ...]

        pairs.each do |p|
          defn = model.definitions[p[:definition]]
          next unless defn

          isect = _aabb_intersection(p[:bb_a], p[:bb_b])
          next unless isect

          key = _bb_key(isect)
          drawn[p[:definition]] ||= []
          next if drawn[p[:definition]].include?(key)
          drawn[p[:definition]] << key

          _add_marker_box(defn.entities, isect, mat)
        end
      end

      def _aabb_intersection(bb1, bb2)
        min_x = [bb1.min.x, bb2.min.x].max
        min_y = [bb1.min.y, bb2.min.y].max
        min_z = [bb1.min.z, bb2.min.z].max
        max_x = [bb1.max.x, bb2.max.x].min
        max_y = [bb1.max.y, bb2.max.y].min
        max_z = [bb1.max.z, bb2.max.z].min
        return nil if max_x <= min_x || max_y <= min_y || max_z <= min_z

        bb = Geom::BoundingBox.new
        bb.add(Geom::Point3d.new(min_x, min_y, min_z))
        bb.add(Geom::Point3d.new(max_x, max_y, max_z))
        bb
      end

      def _bb_key(bb)
        [bb.min.x, bb.min.y, bb.min.z, bb.max.x, bb.max.y, bb.max.z].map { |v| v.round(6) }
      end

      # Add a solid-face box group at the intersection, padded outward.
      def _add_marker_box(entities, bb, mat)
        p  = MARKER_PAD
        x0 = bb.min.x - p;  y0 = bb.min.y - p;  z0 = bb.min.z - p
        x1 = bb.max.x + p;  y1 = bb.max.y + p;  z1 = bb.max.z + p

        g    = entities.add_group
        g.name = MARKER_NAME
        ents = g.entities

        # 6 outward-facing faces (winding: right-hand rule, normal pointing out)
        faces = [
          [[x0,y0,z0],[x1,y0,z0],[x1,y1,z0],[x0,y1,z0]], # bottom  (-Z)
          [[x0,y0,z1],[x0,y1,z1],[x1,y1,z1],[x1,y0,z1]], # top     (+Z)
          [[x0,y0,z0],[x0,y0,z1],[x1,y0,z1],[x1,y0,z0]], # front   (-Y)
          [[x0,y1,z0],[x1,y1,z0],[x1,y1,z1],[x0,y1,z1]], # back    (+Y)
          [[x0,y0,z0],[x0,y1,z0],[x0,y1,z1],[x0,y0,z1]], # left    (-X)
          [[x1,y0,z0],[x1,y0,z1],[x1,y1,z1],[x1,y1,z0]]  # right   (+X)
        ]

        faces.each do |pts|
          f = ents.add_face(pts.map { |c| Geom::Point3d.new(*c) })
          next unless f
          f.material      = mat
          f.back_material = mat
        end
      end

      def _ensure_marker_material(model)
        rgb  = Config::PREVIEW_RGB_OVERLAP
        name = 'EB_overlap_marker'
        mat  = model.materials[name] || model.materials.add(name)
        mat.color = Sketchup::Color.new(*rgb)
        mat.alpha = MARKER_ALPHA
        mat
      end

      # ── Part collection ──────────────────────────────────────────────────────

      # All unique EB component definitions referenced by root-level instances.
      def _eb_definitions(model)
        seen = {}
        model.entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) && e.valid?
          next unless e.definition.name.start_with?('EB | ')
          seen[e.definition.name] ||= e.definition
        end
        seen.values
      end

      # Recursively collect leaf part instances (non-screw, named, raw geometry).
      # Composite groups (no faces in their definition) are transparently recursed.
      def _collect_parts(entities, parent_tr, out)
        entities.each do |e|
          next unless e.valid?

          case e
          when Sketchup::ComponentInstance
            next if e.name.nil? || e.name.empty?
            next if _ignore_overlaps?(e)

            local_tr = parent_tr * e.transformation
            if _leaf_definition?(e.definition)
              out << { name: e.name, bb: _local_bb(e, parent_tr), eid: e.entityID }
            else
              _collect_parts(e.definition.entities, local_tr, out)
            end
          when Sketchup::Group
            next if e.name.nil? || e.name.empty?

            local_tr = parent_tr * e.transformation
            if e.entities.any? { |c| c.is_a?(Sketchup::Face) }
              out << { name: e.name, bb: _local_bb(e, parent_tr), eid: e.entityID }
            else
              _collect_parts(e.entities, local_tr, out)
            end
          end
        end
      end

      # A definition is a leaf when it contains raw faces (not just sub-instances).
      def _leaf_definition?(defn)
        defn.entities.any? { |e| e.is_a?(Sketchup::Face) }
      end

      # Parts opt out of overlap checking via 'ignore_overlaps' on their
      # ComponentDefinition attribute dictionary — set at definition-creation time
      # by the renderer (currently all screw definitions). Any future hardware kind
      # (nails, brackets, …) just needs the same attribute; no validator changes needed.
      def _ignore_overlaps?(inst)
        inst.definition.get_attribute(Config::ATTR_DICT, 'ignore_overlaps')
      end

      # Transform element bounds (parent-local) into the running coordinate frame.
      def _local_bb(element, parent_tr)
        bb = element.bounds
        wb = Geom::BoundingBox.new
        8.times { |i| wb.add(bb.corner(i).transform(parent_tr)) }
        wb
      end

      def _aabb_overlap?(bb1, bb2)
        bb1.max.x > bb2.min.x && bb2.max.x > bb1.min.x &&
          bb1.max.y > bb2.min.y && bb2.max.y > bb1.min.y &&
          bb1.max.z > bb2.min.z && bb2.max.z > bb1.min.z
      end
    end
  end
end
