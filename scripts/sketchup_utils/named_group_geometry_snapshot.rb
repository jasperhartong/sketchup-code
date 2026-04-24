# frozen_string_literal: true

# Generic SketchUp geometry snapshot: world-space AABB per leaf render node, keyed by
# Outliner path. Optional +root_filter+ limits which top-level groups are walked.
#
#   load File.expand_path('sketchup_utils/named_group_geometry_snapshot.rb', scripts_dir)
#   Timmerman::SketchupUtils::NamedGroupGeometrySnapshot.save_snapshot('/tmp/snap.json', model)
#
#   issues = Timmerman::SketchupUtils::NamedGroupGeometrySnapshot.diff_files('a.json', 'b.json')
#   puts issues.empty? ? 'PASS' : issues.join("\n")

module Timmerman
  module SketchupUtils
    module NamedGroupGeometrySnapshot
      class << self
        # @param root_filter [Proc, nil] if given, called as root_filter.call(Sketchup::Group)
        #   for each top-level group; only matching roots are included.
        # @return [Hash] { "Root / Child / …" => { min: [x,y,z], max: [x,y,z] } } in mm
        def snapshot(model = Sketchup.active_model, root_filter: nil)
          result = {}
          model.entities.grep(Sketchup::Group).each do |root|
            next unless root.valid?
            next if root_filter && !root_filter.call(root)

            _walk(root.entities, root.transformation, [root.name], result)
          end
          result
        end

        def save_snapshot(path, model = Sketchup.active_model, root_filter: nil)
          require 'json'
          snap = snapshot(model, root_filter: root_filter)
          File.write(path, JSON.pretty_generate(snap))
          puts "[NamedGroupGeometrySnapshot] #{snap.size} parts → #{path}"
          snap
        end

        # Compares two snapshots (Hashes or JSON file paths).
        # @return [Array<String>] human-readable issues; empty = identical
        def diff(snap_a, snap_b, label_a: 'A', label_b: 'B')
          all_keys = (snap_a.keys + snap_b.keys).uniq.sort
          issues   = []
          all_keys.each do |key|
            a = snap_a[key]
            b = snap_b[key]
            if    a.nil? then issues << "  [ADDED in #{label_b}]  #{key}"
            elsif b.nil? then issues << "  [MISSING in #{label_b}]  #{key}"
            elsif a[:min] != b[:min] || a[:max] != b[:max]
              issues << "  [MISMATCH]  #{key}"
              issues << "    #{label_a}: min=#{a[:min].inspect}  max=#{a[:max].inspect}"
              issues << "    #{label_b}: min=#{b[:min].inspect}  max=#{b[:max].inspect}"
            end
          end
          issues
        end

        def diff_files(path_a, path_b, label_a: 'A', label_b: 'B')
          require 'json'
          parse = lambda do |p|
            JSON.parse(File.read(p)).transform_keys(&:to_s).transform_values do |v|
              { min: v['min'], max: v['max'] }
            end
          end
          diff(parse.call(path_a), parse.call(path_b), label_a: label_a, label_b: label_b)
        end

        private

        def _walk(entities, world_tr, path, result)
          child_nodes = entities.select do |e|
            e.valid? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance))
          end
          if child_nodes.empty?
            min_pt, max_pt = _world_bb(entities, world_tr)
            result[path.join(' / ')] = { min: _mm3(min_pt), max: _mm3(max_pt) }
            return
          end
          child_nodes.each do |child|
            child_entities =
              case child
              when Sketchup::Group then child.entities
              when Sketchup::ComponentInstance then child.definition.entities
              end
            _walk(child_entities, world_tr * child.transformation, path + [child.name], result)
          end
        end

        def _world_bb(entities, world_tr)
          xs = []; ys = []; zs = []
          entities.grep(Sketchup::Face).each do |face|
            face.vertices.each do |v|
              wp = v.position.transform(world_tr)
              xs << wp.x; ys << wp.y; zs << wp.z
            end
          end
          return [Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(0, 0, 0)] if xs.empty?

          [Geom::Point3d.new(xs.min, ys.min, zs.min), Geom::Point3d.new(xs.max, ys.max, zs.max)]
        end

        def _mm3(pt)
          [pt.x.to_mm.round(3), pt.y.to_mm.round(3), pt.z.to_mm.round(3)]
        end
      end
    end
  end
end
