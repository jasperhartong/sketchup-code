# frozen_string_literal: true

# Backend-agnostic driver: given a PartCatalog::View (or raw catalog) and a
# renderer that implements the SketchupUtils::Renderer interface, produce
# scene groups. This is the single code path used for every geometric thing
# (beams, legs, slats, planks, pillows, screws).
#
# Usage:
#   PartRendering.render_view(view,
#                             parent: :root,
#                             renderer: renderer,
#                             layer:    some_layer,
#                             on_beam:  ->(b) { planner.record(b) })
#
# The block hooks (+on_beam+, +on_screw+) let StockPlanner and friends count
# parts without the renderer knowing anything about them.

module Timmerman
  module SketchupUtils
    module PartRendering
      module_function

      ATTR_DICT_KEY_NOTE = 'note'

      # Renders a single catalog view into +parent+. Returns the created root
      # group handle.
      #
      # @param view [PartCatalog::View] must expose .group_name, .parts, .hardware
      # @param parent [Symbol, group-handle] :root or a parent group from the renderer
      # @param renderer [SketchupUtils::Renderer] concrete backend
      # @param layer [Object, nil] backend-specific layer handle (ignored by backends without layers)
      # @param attr_dict [String, nil] dictionary name used for per-part +note+ round-trip
      # @param cut_hosts [Boolean] if true, screws cut countersink + hole on hosts
      # @param countersink_first [Boolean] countersink pocket then through hole (vs single clearance bore)
      # @param through_hole [Boolean] when countersink_first, skip the bore step if false
      def render_view(view, parent:, renderer:, layer: nil,
                      attr_dict: nil,
                      cut_hosts: false, countersink_first: false, through_hole: true,
                      on_beam: nil, on_screw: nil)
        root = renderer.create_group(view.group_name, parent: parent, layer: layer)

        part_groups = {}
        view.parts.each do |part|
          g = _render_part(
            root,
            part,
            renderer: renderer,
            layer: layer,
            attr_dict: attr_dict,
            reusable: !cut_hosts
          )
          part_groups[part.name] = g
          on_beam&.call(part) if part.is_a?(Parts::Beam)
        end

        view.hardware.each do |placement|
          host_group = part_groups[placement.host_name]
          unless host_group
            warn "[PartRendering] host group not found for screw #{placement.name.inspect}: #{placement.host_name.inspect}"
            next
          end
          host_part = view.parts.find { |p| p.name == placement.host_name }
          _render_screw(root, host_group, host_part, placement,
                        renderer: renderer, layer: layer,
                        cut_hosts: cut_hosts, countersink_first: countersink_first,
                        through_hole: through_hole)
          on_screw&.call(placement)
        end

        root
      end

      # ── internal ─────────────────────────────────────────────────────────

      def _render_part(parent_group, part, renderer:, layer:, attr_dict:, reusable:)
        g = if renderer.respond_to?(:create_part_box)
              renderer.create_part_box(
                part.name,
                parent: parent_group,
                layer: layer,
                size: [part.dx, part.dy, part.dz],
                transform: Transform.translation([part.x, part.y, part.z]),
                reusable: reusable
              )
            else
              renderer.create_group(part.name, parent: parent_group, layer: layer)
            end

        if attr_dict && part.note && !part.note.empty?
          renderer.set_group_attribute(g, attr_dict, ATTR_DICT_KEY_NOTE, part.note)
        end
        unless renderer.respond_to?(:create_part_box)
          renderer.add_box(g, at: [0, 0, 0], size: [part.dx, part.dy, part.dz])
          renderer.set_group_transform(g, Transform.translation([part.x, part.y, part.z]))
        end
        g
      end

      def _render_screw(root, host_group, host_part, placement,
                        renderer:, layer:, cut_hosts:, countersink_first:, through_hole:)
        geo = PocketGeometry.face_geometry(
          placement.face, host_part.dx, host_part.dy, host_part.dz, placement.u, placement.v
        )
        PocketGeometry.apply_pocket_tilt!(geo, placement)

        if cut_hosts && PocketGeometry.perpendicular_to_face?(placement)
          begin
            renderer.cut_pocket_and_hole(host_group, geo: geo, spec: placement.spec,
                                         countersink_first: countersink_first,
                                         through_hole: through_hole)
          rescue StandardError => e
            warn "[PartRendering] hole/countersink failed for #{placement.name.inspect}: #{e.message}"
          end
        end

        transform = _screw_transform(host_part, geo)
        renderer.add_screw_body(root, name: placement.name, transform: transform,
                                spec: placement.spec,
                                shaft_length_index: placement.shaft_length_index,
                                layer: layer)
      rescue StandardError => e
        warn "[PartRendering] screw #{placement.name.inspect}: #{e.message}"
      end

      # Screw local: origin on outer flush point, +Z = outward (head), shaft in -Z.
      # Composed relative to host part's local origin (the host group already
      # carries the translation to part.at).
      def _screw_transform(host_part, geo)
        xaxis, yaxis, zaxis = PocketGeometry.orthonormal_frame(geo[:outward])
        ox, oy, oz = geo[:origin]
        # Assemble a local-to-host 4x4: columns = xaxis, yaxis, zaxis, origin.
        # Then compose with host translation so the screw is in root-local space.
        local_to_host = Transform.new([
                                        [xaxis[0], yaxis[0], zaxis[0], ox],
                                        [xaxis[1], yaxis[1], zaxis[1], oy],
                                        [xaxis[2], yaxis[2], zaxis[2], oz],
                                        [0.0,      0.0,      0.0,      1.0]
                                      ])
        host_translation = Transform.translation([host_part.x, host_part.y, host_part.z])
        host_translation * local_to_host
      end
    end
  end
end
