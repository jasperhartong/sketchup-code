# frozen_string_literal: true

# Pure-Ruby helpers for pocket-screw geometry — no SketchUp dependency.
#
# Operates on plain 3-element arrays `[x, y, z]` for both points and vectors.
# Renderer backends (e.g. SketchUp, OBJ) convert to their native 3D types at
# the API boundary.

module Timmerman
  module SketchupUtils
    module PocketGeometry
      module_function

      # Local origin + outward normal + axis thickness for a screw placement
      # on an axis-aligned box face.
      #
      # @param face [Symbol] one of Hardware::BoxFace::ALL
      # @param dx [Numeric] box extents (in SketchUp length units; `.to_f` ok)
      # @return [Hash] {origin:, outward:, axis_thickness:, face_key:, dx:, dy:, dz:}
      def face_geometry(face, dx, dy, dz, u, v)
        dx_f = dx.to_f; dy_f = dy.to_f; dz_f = dz.to_f
        u_f  = u.to_f;  v_f  = v.to_f

        case face
        when :min_x
          { origin: [0.0, u_f, v_f], outward: [-1.0, 0.0, 0.0], axis_thickness: dx_f,
            face_key: :min_x, dx: dx_f, dy: dy_f, dz: dz_f }
        when :max_x
          { origin: [dx_f, u_f, v_f], outward: [1.0, 0.0, 0.0], axis_thickness: dx_f,
            face_key: :max_x, dx: dx_f, dy: dy_f, dz: dz_f }
        when :min_y
          { origin: [u_f, 0.0, v_f], outward: [0.0, -1.0, 0.0], axis_thickness: dy_f,
            face_key: :min_y, dx: dx_f, dy: dy_f, dz: dz_f }
        when :max_y
          { origin: [u_f, dy_f, v_f], outward: [0.0, 1.0, 0.0], axis_thickness: dy_f,
            face_key: :max_y, dx: dx_f, dy: dy_f, dz: dz_f }
        when :min_z
          { origin: [u_f, v_f, 0.0], outward: [0.0, 0.0, -1.0], axis_thickness: dz_f,
            face_key: :min_z, dx: dx_f, dy: dy_f, dz: dz_f }
        when :max_z
          { origin: [u_f, v_f, dz_f], outward: [0.0, 0.0, 1.0], axis_thickness: dz_f,
            face_key: :max_z, dx: dx_f, dy: dy_f, dz: dz_f }
        else
          raise ArgumentError, "unknown face #{face.inspect}"
        end
      end

      # Apply pocket tilt (in-place) to +geo[:outward]+ according to a placement.
      # Returns the mutated geo hash.
      #
      # With tilt 0 and +pocket_away_from_host: true+, reverses the outward so the
      # shaft runs across the interface into the mate. With tilt > 0, rotates the
      # shaft in the (normal, tangent) plane toward +pocket_tilt_toward+.
      def apply_pocket_tilt!(geo, placement)
        o = normalize(geo[:outward])
        rad = placement.pocket_tilt_from_normal_deg * Math::PI / 180.0

        if rad.abs < 1e-9
          geo[:outward] = placement.pocket_away_from_host ? vec_neg(o) : o
          return geo
        end

        t = pocket_tangent_unit(placement.face, placement.pocket_tilt_toward)
        base = placement.pocket_away_from_host ? o : vec_neg(o)
        shaft = normalize(vec_combine(Math.cos(rad), base, Math.sin(rad), t))
        geo[:outward] = vec_neg(shaft)
        geo
      end

      # Returns true if the screw goes straight in with no outward inversion.
      # (i.e. "head on the outer side, shaft perpendicular into the host")
      def perpendicular_to_face?(placement)
        placement.pocket_tilt_from_normal_deg.abs < 1e-9 && !placement.pocket_away_from_host
      end

      # Unit in-plane tangent on a box face. See BoxFace UV mapping.
      def pocket_tangent_unit(face, toward)
        u_hat, v_hat = case face
                       when :min_x, :max_x then [[0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
                       when :min_y, :max_y then [[1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]
                       when :min_z, :max_z then [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
                       else
                         raise ArgumentError, "unknown face #{face.inspect}"
                       end
        vec = case toward
              when :pos_u then u_hat
              when :neg_u then vec_neg(u_hat)
              when :pos_v then v_hat
              when :neg_v then vec_neg(v_hat)
              else
                raise ArgumentError, "unknown toward #{toward.inspect}"
              end
        normalize(vec)
      end

      # Screw local frame: +Z = outward (head); +X and +Y orthonormal in-plane.
      # @return [Array(<3-vec>,<3-vec>,<3-vec>)] [xaxis, yaxis, zaxis]
      def orthonormal_frame(outward)
        z = normalize(outward)
        ref = vec_parallel?(z, [0.0, 0.0, 1.0]) ? [1.0, 0.0, 0.0] : [0.0, 0.0, 1.0]
        x = normalize(vec_cross(z, ref))
        y = normalize(vec_cross(z, x))
        [x, y, z]
      end

      # ── vector helpers ───────────────────────────────────────────────────

      def vec_neg(v)             = [-v[0], -v[1], -v[2]]
      def vec_add(a, b)          = [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
      def vec_scale(a, s)        = [a[0] * s, a[1] * s, a[2] * s]
      def vec_dot(a, b)          = (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])

      def vec_cross(a, b)
        [(a[1] * b[2]) - (a[2] * b[1]),
         (a[2] * b[0]) - (a[0] * b[2]),
         (a[0] * b[1]) - (a[1] * b[0])]
      end

      def vec_combine(a, va, b, vb)
        [(a * va[0]) + (b * vb[0]),
         (a * va[1]) + (b * vb[1]),
         (a * va[2]) + (b * vb[2])]
      end

      def vec_length(v) = Math.sqrt(vec_dot(v, v))

      def normalize(v)
        len = vec_length(v)
        return [0.0, 0.0, 0.0] if len < 1e-12

        [v[0] / len, v[1] / len, v[2] / len]
      end

      def vec_parallel?(a, b, tol: 1e-9)
        ax, ay, az = normalize(a)
        bx, by, bz = normalize(b)
        ((ay * bz) - (az * by)).abs < tol &&
          ((az * bx) - (ax * bz)).abs < tol &&
          ((ax * by) - (ay * bx)).abs < tol
      end
    end
  end
end
