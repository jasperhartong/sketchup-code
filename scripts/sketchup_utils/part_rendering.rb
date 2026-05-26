# frozen_string_literal: true

# Low-level screw-rendering helper used by DeclarationsCompiler.
# The higher-level `render_view` / `_render_part` path (PartCatalog-driven)
# has been removed; only the screw pipeline below is still active.

module Timmerman
  module SketchupUtils
    module PartRendering
      module_function

      # Keep screw heads visibly above the entry face to avoid z-fighting.
      SCREW_SURFACE_PROTRUSION = 0.35.mm

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
        ox, oy, oz = _offset_point_along_axis(geo[:origin], zaxis, SCREW_SURFACE_PROTRUSION)
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

      def _offset_point_along_axis(point, axis, distance)
        [
          point[0] + (axis[0] * distance),
          point[1] + (axis[1] * distance),
          point[2] + (axis[2] * distance)
        ]
      end
    end
  end
end
