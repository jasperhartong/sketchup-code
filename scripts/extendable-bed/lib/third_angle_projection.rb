# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    remove_const :ThirdAngleProjection if const_defined?(:ThirdAngleProjection, false)

    # Creates an EB_3rdAngle group containing six rotated copies of the
    # retracted bed pair (EB_Ret_Back + EB_Ret_Front component definitions)
    # laid out in 3rd Angle Projection (ANSI / American standard), viewed
    # from a top-down camera.
    #
    # Layout (each view is one sub-group; all share the same container):
    #
    #                    [ Plan / Top ]
    #   [ Left ] [ Front (foot end) ] [ Right ] [ Back (head end) ]
    #                    [ Bottom ]
    #
    # Each view rotates the pair so the face of interest points +Z (up),
    # then translates it to the 3rd-angle layout position inside the
    # container. The container itself is placed at +third_angle_row_y+ on the
    # world Y axis, well clear of the other preview rows.
    module ThirdAngleProjection
      # Vertical spacing (plan/bottom row) between views.
      LAYOUT_GAP = 300.mm
      # Horizontal spacing between left / front / right / back views.
      H_LAYOUT_GAP = 600.mm
      # How far the height dimension line is pushed to the left of the left view.
      DIM_OFFSET = 200.mm

      # Short labels for the 6 view sub-groups (used as group names).
      VIEW_NAMES = %i[front plan bottom right left back].freeze

      module_function

      # Build the 3rd angle container group and register a scene for it.
      #
      # @param model   [Sketchup::Model]
      # @param renderer [SketchupUtils::SketchUpRenderer]
      # @param config  [Config]
      # @param layer   [Object]   layer handle returned by renderer.ensure_layer
      # @param scenes  [Hash]     { key => SceneScope } from PreviewScenes.open_scopes
      def create_scene(model, renderer, config:, layer:, scenes:)
        return unless model && renderer && scenes

        back_def  = model.definitions[Config::GROUP_RET_BACK]
        front_def = model.definitions[Config::GROUP_RET_FRONT]
        unless back_def && front_def
          warn '[3AP] EB_Ret definitions not found — skipping 3rd angle scene.'
          return
        end

        foot_y = config.retracted_foot_world_y
        bb     = _combined_bounds(back_def, front_def, foot_y)

        container = renderer.create_group(Config::GROUP_3RD_ANGLE, parent: :root, layer: layer)
        unless container.respond_to?(:entities)
          warn '[3AP] renderer did not return a SketchUp group — skipping.'
          return
        end

        renderer.set_group_transform(
          container,
          SketchupUtils::Transform.translation([0, config.third_angle_row_y, 0])
        )

        _build_views(container, back_def, front_def, foot_y, bb)

        scenes[:third_angle]&.track(container)
        container
      end

      # ── Private helpers ──────────────────────────────────────────────────

      # Combined bounding box of the retracted pair in pair-local space:
      # back at origin, front offset by +foot_y+ along Y.
      def _combined_bounds(back_def, front_def, foot_y)
        bb = Geom::BoundingBox.new
        t_front = Geom::Transformation.translation(Geom::Vector3d.new(0, foot_y, 0))
        8.times { |i| bb.add(back_def.bounds.corner(i)) }
        8.times { |i| bb.add(front_def.bounds.corner(i).transform(t_front)) }
        bb
      end

      # Place one sub-group per view inside +container+, then add annotations.
      def _build_views(container, back_def, front_def, foot_y, bb)
        rotations = _view_rotations
        positions = _layout_positions(bb)
        t_front   = Geom::Transformation.translation(Geom::Vector3d.new(0, foot_y, 0))

        VIEW_NAMES.each do |view|
          rot    = rotations[view]
          lx, ly = positions[view]
          t_container = _view_transform(bb, rot, lx, ly)

          sub = container.entities.add_group
          sub.name = "EB_3AP_#{view}"

          sub.entities.add_instance(back_def,  Geom::Transformation.new).name = back_def.name
          sub.entities.add_instance(front_def, t_front).name                  = front_def.name

          sub.transformation = t_container
        end

        _add_annotations(container, back_def, bb, positions)
      end

      # All dimension annotations on the container.
      def _add_annotations(container, back_def, bb, positions)
        lx  = positions[:left][0]
        l   = bb.max.y - bb.min.y   # bed length (retracted)
        h   = bb.max.z - bb.min.z   # bed height
        cx  = bb.center.x
        cy  = bb.center.y
        cz  = bb.center.z

        left_edge_x   = lx - l / 2.0
        bottom_edge_y = -(h / 2.0 + LAYOUT_GAP + l / 2.0)   # bottom edge of bottom view

        pillow_bb    = _big_pillow_bounds(back_def)
        seat_top_z   = pillow_bb ? pillow_bb.max.z : bb.max.z

        right_edge_x       = lx + l / 2.0
        bottom_edge_y_left = bb.min.z - cz   # ground level in left view container Y
        seat_top_y         = seat_top_z - cz

        # In the left view, original Y maps to container -X:
        #   container_x = -y + lx + cy
        pillow_x1 = lx + cy - pillow_bb.min.y if pillow_bb   # head end of pillow
        pillow_x2 = lx + cy - pillow_bb.max.y if pillow_bb   # foot end of pillow

        # Seat height: left of left view, vertical, offset left.
        _add_dimension(
          container,
          Geom::Point3d.new(left_edge_x, bottom_edge_y_left, 0),
          Geom::Point3d.new(left_edge_x, seat_top_y,         0),
          Geom::Vector3d.new(-DIM_OFFSET, 0, 0)
        )

        # Bed length (retracted): bottom of left view, horizontal, offset down.
        _add_dimension(
          container,
          Geom::Point3d.new(left_edge_x,  bottom_edge_y_left, 0),
          Geom::Point3d.new(right_edge_x, bottom_edge_y_left, 0),
          Geom::Vector3d.new(0, -DIM_OFFSET, 0)
        )

        # Pillow (seat) length: top of left view, horizontal, offset up.
        if pillow_bb
          _add_dimension(
            container,
            Geom::Point3d.new(pillow_x1, seat_top_y, 0),
            Geom::Point3d.new(pillow_x2, seat_top_y, 0),
            Geom::Vector3d.new(0, DIM_OFFSET, 0)
          )
        end

        # Bed width: bottom of front view, horizontal, offset down.
        # Front view: R_z(180°)·R_x(90°) maps original X → container -X,
        # so width is symmetric: -w/2 … +w/2 around x=0.
        w = bb.max.x - bb.min.x
        _add_dimension(
          container,
          Geom::Point3d.new(-w / 2.0, -h / 2.0, 0),
          Geom::Point3d.new( w / 2.0, -h / 2.0, 0),
          Geom::Vector3d.new(0, -DIM_OFFSET, 0)
        )
      end

      # Add a single DimensionLinear to +container+.
      def _add_dimension(container, p1, p2, offset)
        container.entities.add_dimension_linear(p1, p2, offset)
      end

      # Returns the bounding box of the "EB | pillow | big" group inside +back_def+
      # in the definition's local space (= pair-local space, back at origin).
      def _big_pillow_bounds(back_def)
        inst = back_def.entities.find do |e|
          (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
            e.name == 'EB | pillow | big'
        end
        inst&.bounds
      end

      # 6 rotations that bring each face of the bed to face +Z (visible from top).
      #
      # Coordinate convention: +Y = head→foot, +X = left→right, +Z = up.
      #
      #   :front   R_x(+90°)   +Y face (foot end) → +Z
      #   :back    R_x(-90°)   −Y face (head end) → +Z
      #   :right   R_y(−90°)   +X face (right)    → +Z
      #   :left    R_y(+90°)   −X face (left)      → +Z
      #   :plan    identity     +Z face (top)       → +Z  (already up)
      #   :bottom  R_x(180°)   −Z face (bottom)    → +Z
      def _view_rotations
        o = Geom::Point3d.new(0, 0, 0)
        x = Geom::Vector3d.new(1, 0, 0)
        y = Geom::Vector3d.new(0, 1, 0)
        z = Geom::Vector3d.new(0, 0, 1)
        {
          front:  Geom::Transformation.rotation(o, z, 180.degrees) *
                  Geom::Transformation.rotation(o, x,  90.degrees),
          back:   Geom::Transformation.rotation(o, x, -90.degrees),
          right:  Geom::Transformation.rotation(o, z, -90.degrees) *
                  Geom::Transformation.rotation(o, y, -90.degrees),
          left:   Geom::Transformation.rotation(o, z,  90.degrees) *
                  Geom::Transformation.rotation(o, y,  90.degrees),
          plan:   Geom::Transformation.new,
          bottom: Geom::Transformation.rotation(o, x, 180.degrees)
        }
      end

      # Layout centres (lx, ly) for each view in the container's local XY plane.
      #
      # Footprints after rotation (W=bed width, L=bed length, H=bed height):
      #   front / back : W × H
      #   right / left : H × L
      #   plan / bottom: W × L
      #
      # Arrangement (3rd Angle / ANSI):
      #
      #             [Plan]
      #   [Left] [Front] [Right] [Back]
      #             [Bottom]
      #
      # Front view is centred at (0, 0); all others derive from it.
      def _layout_positions(bb)
        g  = LAYOUT_GAP
        hg = H_LAYOUT_GAP
        w  = bb.max.x - bb.min.x   # bed width
        l  = bb.max.y - bb.min.y   # bed length (retracted)
        h  = bb.max.z - bb.min.z   # bed height

        {
          front:  [0,                           0                      ],
          plan:   [0,                           h / 2.0 + g + l / 2.0 ],
          bottom: [0,                         -(h / 2.0 + g + l / 2.0)],
          right:  [ w / 2.0 + hg + h / 2.0,    0                      ],
          left:   [-(w / 2.0 + hg + h / 2.0),  0                      ],
          back:   [ w / 2.0 + hg + h + hg + h / 2.0, 0               ]
        }
      end

      # Transform (in container local space) that rotates the pair so a face
      # points up, then centres it at (layout_x, layout_y).
      #
      # Strategy: apply +rotation+ about the origin, find where the bounding-box
      # centre lands (rotated_c), then translate so rotated_c → (lx, ly).
      def _view_transform(bb, rotation, layout_x, layout_y)
        c         = bb.center
        rotated_c = c.transform(rotation)
        tx        = layout_x - rotated_c.x
        ty        = layout_y - rotated_c.y
        Geom::Transformation.translation(Geom::Vector3d.new(tx, ty, 0)) * rotation
      end
    end
  end
end
