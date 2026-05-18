# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Checks that no two parts in +OVERLAP_CHECK_NAME_RE+ (structural solids and pillows;
    # not screws or helpers) have overlapping axis-aligned bounding boxes within each
    # preview variant
    # (back root + front root at their placed world transforms). Touching faces are
    # allowed; only true volumetric overlap is flagged.
    #
    # NEVER add exceptions, allowlists, or “intentional overlap” skips in this class.
    # If the validator reports an overlap, fix the geometry in Config / frame assembly —
    # do not weaken the check.
    #
    # Usage:
    #   Validator.new(config).validate(model)        # prints + returns pairs
    #   Validator.new(config).overlapping_pairs(model)  # just returns pairs
    class Validator
      def initialize(config)
        @config = config
      end

      # Prints a summary; returns the overlap list (empty = OK).
      def validate(model = Sketchup.active_model)
        pairs = overlapping_pairs(model)
        if pairs.empty?
          puts '[EB validate] OK — no part bounding-box overlaps in any preview variant.'
        else
          puts "[EB validate] FAIL — #{pairs.size} overlapping part pair(s) (includes pillows vs frames):"
          pairs.each { |p| puts _format_overlap_line(p) }
        end
        pairs
      end

      # Returns an array of hashes per overlapping pair:
      #   :variant, :roots, :half_a, :part_a, :half_b, :part_b
      def overlapping_pairs(model = Sketchup.active_model)
        pairs = []
        _eb_preview_pairs(model).each do |preview|
          items = []
          _collect_solids(preview[:back].entities, preview[:back].transformation, items, half: :back)
          _collect_solids(preview[:front].entities, preview[:front].transformation, items, half: :front)

          (0...items.size).each do |i|
            ((i + 1)...items.size).each do |j|
              a = items[i]
              b = items[j]
              next if a[:eid] == b[:eid]
              next unless _aabb_overlap?(a[:bb], b[:bb])

              pairs << {
                variant:    preview[:variant],
                roots:      preview[:roots],
                back_root:  preview[:back].name,
                front_root: preview[:front].name,
                half_a:     a[:half],
                part_a:     a[:name],
                half_b:     b[:half],
                part_b:     b[:name]
              }
            end
          end
        end
        pairs
      end

      # Unique [root_group_name, part_name] for every part in at least one overlap.
      def overlap_part_keys(overlaps)
        require 'set'
        keys = Set.new
        overlaps.each do |p|
          keys << [p[:back_root], p[:part_a]]  if p[:half_a] == :back
          keys << [p[:front_root], p[:part_a]] if p[:half_a] == :front
          keys << [p[:back_root], p[:part_b]]  if p[:half_b] == :back
          keys << [p[:front_root], p[:part_b]] if p[:half_b] == :front
        end
        keys.to_a
      end

      # Magenta (default) on each overlapping part. Returns count painted.
      def highlight_overlapping_parts(renderer, model, overlaps,
                                        rgb: Config::PREVIEW_RGB_OVERLAP)
        painted = 0
        overlap_part_keys(overlaps).each do |root_name, part_name|
          root = model.entities.grep(Sketchup::Group).find { |g| g.valid? && g.name == root_name }
          next unless root

          child = root.entities.find { |e| e.valid? && e.name == part_name }
          next unless child

          if renderer.respond_to?(:paint_structural_part_highlight)
            renderer.paint_structural_part_highlight(child, rgb)
          elsif renderer.respond_to?(:paint_named_children_force)
            renderer.paint_named_children_force(root, [part_name], rgb)
          else
            renderer.paint_named_children(root, [part_name], rgb)
          end
          painted += 1
        end
        painted
      end

      private

      def _format_overlap_line(p)
        "  #{p[:variant]} (#{p[:roots]}): " \
          "[#{p[:half_a]}] #{p[:part_a]}  ⟷  [#{p[:half_b]}] #{p[:part_b]}"
      end

      def _eb_preview_pairs(model)
        backs = _eb_root_groups(model).select { |g| g.name.end_with?('_Back') }
        backs.filter_map do |back|
          front_name = back.name.sub(/_Back\z/, '_Front')
          front = model.entities.grep(Sketchup::Group).find { |g| g.valid? && g.name == front_name }
          next unless front

          {
            back:    back,
            front:   front,
            roots:   "#{back.name} + #{front.name}",
            variant: _variant_label(back.name)
          }
        end
      end

      def _variant_label(back_root_name)
        Config::EXTENSION_PAIR_DISPLAY_NAME_BY_BACK_ROOT[back_root_name] ||
          (back_root_name[/\AEB_Step(\d+)_Back\z/, 1] && "Construction step #{$1}") ||
          back_root_name
      end

      def _eb_root_groups(model)
        model.entities.grep(Sketchup::Group).select do |g|
          Config::GROUP_NAME_RE.match?(g.name) ||
            Config::SINGLE_PAIR_ROOTS.include?(g.name)
        end
      end

      def _collect_solids(entities, parent_world_tr, out, half:)
        entities.each do |e|
          next unless e.valid?

          case e
          when Sketchup::Group
            if _overlap_check_part?(e.name)
              out << {
                name: e.name,
                half: half,
                bb:   _world_bb(e, parent_world_tr),
                eid:  e.entityID
              }
            end
            _collect_solids(e.entities, parent_world_tr * e.transformation, out, half: half)
          when Sketchup::ComponentInstance
            if _overlap_check_part?(e.name)
              out << {
                name: e.name,
                half: half,
                bb:   _world_bb(e, parent_world_tr),
                eid:  e.entityID
              }
            end
            _collect_solids(e.definition.entities, parent_world_tr * e.transformation, out, half: half)
          end
        end
      end

      # Parent-space bounds corners → world AABB (+parent_world_tr+ only; element bounds
      # are already in the parent coordinate system per Drawingelement#bounds).
      def _world_bb(element, parent_world_tr)
        bb = element.bounds
        wb = Geom::BoundingBox.new
        8.times { |i| wb.add(bb.corner(i).transform(parent_world_tr)) }
        wb
      end

      def _overlap_check_part?(name)
        Config::SOLID_NAME_RE.match?(name) || Config::PILLOW_NAME_RE.match?(name)
      end

      def _aabb_overlap?(bb1, bb2)
        bb1.max.x > bb2.min.x && bb2.max.x > bb1.min.x &&
          bb1.max.y > bb2.min.y && bb2.max.y > bb1.min.y &&
          bb1.max.z > bb2.min.z && bb2.max.z > bb1.min.z
      end
    end
  end
end
