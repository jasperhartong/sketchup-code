# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Checks that no two structural solid parts (beams and legs, not slats or
    # pillows) have overlapping axis-aligned bounding boxes within the same root
    # group.  Touching faces are allowed; only true volumetric overlap is flagged.
    #
    # Usage:
    #   Validator.new(config).validate(model)        # prints + returns pairs
    #   Validator.new(config).overlapping_pairs(model)  # just returns pairs
    class Validator
      def initialize(config)
        @config = config
      end

      # Prints a one-line summary; returns the overlap list (empty = OK).
      def validate(model = Sketchup.active_model)
        pairs = overlapping_pairs(model)
        if pairs.empty?
          puts '[EB validate] OK — no beam/leg bounding-box overlaps within any EB root.'
        else
          puts "[EB validate] #{pairs.size} overlapping beam/leg pair(s):"
          pairs.each { |p| puts "  #{p[:root]}: #{p[:a]}  ⟷  #{p[:b]}" }
        end
        pairs
      end

      # Returns an array of { root:, a:, b: } hashes for each overlapping pair.
      def overlapping_pairs(model = Sketchup.active_model)
        pairs = []
        _eb_root_groups(model).each do |root|
          next unless root.valid?

          items = []
          _collect_solids(root.entities, root.transformation, items)

          (0...items.size).each do |i|
            ((i + 1)...items.size).each do |j|
              a = items[i]
              b = items[j]
              next if a[:eid] == b[:eid]
              next unless _aabb_overlap?(a[:bb], b[:bb])

              pairs << { root: root.name, a: a[:name], b: b[:name] }
            end
          end
        end
        pairs
      end

      private

      # ── SketchUp traversal ─────────────────────────────────────────────────

      def _eb_root_groups(model)
        model.entities.grep(Sketchup::Group).select do |g|
          Config::GROUP_NAME_RE.match?(g.name) ||
            Config::SINGLE_PAIR_ROOTS.include?(g.name)
        end
      end

      # Recursively collects all beam/leg groups with their world-space AABBs.
      # +parent_world_tr+ is the accumulated transformation to world space.
      def _collect_solids(entities, parent_world_tr, out)
        entities.grep(Sketchup::Group).each do |g|
          next unless g.valid?

          if Config::SOLID_NAME_RE.match?(g.name)
            out << {
              name: g.name,
              bb:   _world_bb(g, parent_world_tr),
              eid:  g.entityID
            }
          end
          _collect_solids(g.entities, parent_world_tr * g.transformation, out)
        end
      end

      # World-space bounding box for a group.
      # Group#bounds corners are already in *parent* coordinates
      # (Drawingelement#bounds), so we apply parent_world_tr, not the group's
      # own transformation.
      def _world_bb(group, parent_world_tr)
        bb = group.bounds
        wb = Geom::BoundingBox.new
        8.times { |i| wb.add(bb.corner(i).transform(parent_world_tr)) }
        wb
      end

      # True if the two AABBs have a non-zero volumetric intersection.
      # Touching faces (equal extents) are explicitly excluded.
      def _aabb_overlap?(bb1, bb2)
        bb1.max.x > bb2.min.x && bb2.max.x > bb1.min.x &&
          bb1.max.y > bb2.min.y && bb2.max.y > bb1.min.y &&
          bb1.max.z > bb2.min.z && bb2.max.z > bb1.min.z
      end
    end
  end
end
