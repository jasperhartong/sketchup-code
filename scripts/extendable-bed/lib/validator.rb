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
      def initialize(_config = nil); end

      # Prints a summary; returns the overlap list (empty = OK).
      def validate(model = Sketchup.active_model)
        pairs = overlapping_pairs(model)
        if pairs.empty?
          puts '[EB validate] OK — no part bounding-box overlaps.'
        else
          puts "[EB validate] FAIL — #{pairs.size} overlapping part pair(s):"
          pairs.each { |p| puts _format_overlap_line(p) }
        end
        pairs
      end

      # Returns an array of hashes per overlapping pair:
      #   :definition, :part_a, :part_b
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

              pairs << { definition: defn.name, part_a: a[:name], part_b: b[:name] }
            end
          end
        end
        pairs
      end

      private

      def _format_overlap_line(p)
        "  [#{p[:definition]}]  #{p[:part_a]}  ⟷  #{p[:part_b]}"
      end

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
            next if _screw_instance?(e)

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

      # Screw instances are identified by their definition name prefix set by
      # SketchupRenderer#_screw_definition (e.g. "EB::Screw::eb_pocket_4mm|...").
      def _screw_instance?(inst)
        inst.definition.name.start_with?('EB::Screw::')
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
