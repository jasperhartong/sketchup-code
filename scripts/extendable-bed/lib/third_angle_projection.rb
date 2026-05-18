# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    remove_const :ThirdAngleProjection if const_defined?(:ThirdAngleProjection, false)

    # Builds EB_3rdAngle / EB_3rdAngleExt groups — six rotated copies of a bed
    # pair laid out in 3rd Angle Projection (ANSI / American standard), viewed
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
    # container. Which bed pair to use and which dimension annotations to add
    # are specified via a +ProjectionVariant+.
    module ThirdAngleProjection
      # Vertical spacing (plan/bottom row) between views.
      LAYOUT_GAP = 300.mm
      # Horizontal spacing between left / front / right / back views.
      H_LAYOUT_GAP = 1200.mm
      # Perpendicular distance from the view edge to the dimension line.
      DIM_OFFSET = 200.mm

      # Short labels for the 6 view sub-groups (used as group names).
      VIEW_NAMES = %i[front plan bottom right left back].freeze

      # Immutable configuration for one projection instance.
      #
      # @param back_def_name  [String]         ComponentDefinition name for the back frame
      # @param front_def_name [String]         ComponentDefinition name for the front frame
      # @param foot_y         [Float]          Y offset of the front frame in pair-local space
      # @param container_name [String]         SketchUp Group name for this projection
      # @param scene_key      [Symbol]         Key in the scenes Hash from PreviewScenes
      # @param annotations    [Array<Symbol>]  Ordered list of _dim_* methods to call
      # (row_y is not stored here — callers pass it explicitly so projections can be
      #  chained using each container's actual bounding-box extent.)
      ProjectionVariant = Struct.new(
        :back_def_name, :front_def_name, :foot_y,
        :container_name, :scene_key,
        :annotations,
        keyword_init: true
      )

      module_function

      # ── Variant factories ─────────────────────────────────────────────────

      def retracted_variant(config)
        ProjectionVariant.new(
          back_def_name:  Config::GROUP_RET_BACK,
          front_def_name: Config::GROUP_RET_FRONT,
          foot_y:         config.retracted_foot_world_y,
          container_name: Config::GROUP_3RD_ANGLE,
          scene_key:      :third_angle,
          annotations:    %i[seat_height bed_length pillow_length bed_width]
        )
      end

      def extended_variant(config)
        ProjectionVariant.new(
          back_def_name:  Config::GROUP_EXT_BACK,
          front_def_name: Config::GROUP_EXT_FRONT,
          foot_y:         config.extended_front_foot_world_y,
          container_name: Config::GROUP_3RD_ANGLE_EXT,
          scene_key:      :third_angle_ext,
          annotations:    %i[seat_height bed_length pillows_length bed_width]
        )
      end

      # ── Public entry point ────────────────────────────────────────────────

      # Build the projection container group for +variant+ and register its scene.
      #
      # @param model    [Sketchup::Model]
      # @param renderer [SketchupUtils::SketchUpRenderer]
      # @param variant  [ProjectionVariant]
      # @param row_y    [Float]  World Y centre of this container.
      # @param layer    [Object]  layer handle returned by renderer.ensure_layer
      # @param scenes   [Hash]   { key => SceneScope } from PreviewScenes.open_scopes
      # @return [Float, nil]  World Y of the container's bottom edge (for chaining).
      def create_scene(model, renderer, variant:, row_y:, layer:, scenes:)
        return unless model && renderer && scenes

        back_def  = model.definitions[variant.back_def_name]
        front_def = model.definitions[variant.front_def_name]
        unless back_def && front_def
          warn "[3AP] #{variant.back_def_name} / #{variant.front_def_name} not found — skipping."
          return
        end

        bb = _combined_bounds(back_def, front_def, variant.foot_y)

        container = renderer.create_group(variant.container_name, parent: :root, layer: layer)
        unless container.respond_to?(:entities)
          warn '[3AP] renderer did not return a SketchUp group — skipping.'
          return
        end

        renderer.set_group_transform(
          container,
          SketchupUtils::Transform.translation([0, row_y, 0])
        )

        _build_views(container, back_def, front_def, variant.foot_y, bb,
                     annotations: variant.annotations)

        scenes[variant.scene_key]&.track(container)

        # Return the world Y of the lowest point of this container so the caller
        # can position the next projection directly below without overlap.
        row_y - _y_half_extent(bb)
      end

      # Half the total Y span of a projection container (local Y).
      # The extremes are the top of the plan view and the bottom of the bottom view,
      # both of which extend ±(h/2 + LAYOUT_GAP + l) from the centre.
      def _y_half_extent(bb)
        l = bb.max.y - bb.min.y
        h = bb.max.z - bb.min.z
        h / 2.0 + LAYOUT_GAP + l
      end

      # ── Private helpers ───────────────────────────────────────────────────

      # Combined bounding box of the pair in pair-local space:
      # back at origin, front offset by +foot_y+ along Y.
      def _combined_bounds(back_def, front_def, foot_y)
        bb = Geom::BoundingBox.new
        t_front = Geom::Transformation.translation(Geom::Vector3d.new(0, foot_y, 0))
        8.times { |i| bb.add(back_def.bounds.corner(i)) }
        8.times { |i| bb.add(front_def.bounds.corner(i).transform(t_front)) }
        bb
      end

      # Place one sub-group per view inside +container+, then add annotations.
      def _build_views(container, back_def, front_def, foot_y, bb, annotations:)
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

        _add_annotations(container, back_def, bb, positions, annotations,
                         front_def: front_def, foot_y: foot_y)
      end

      # Dispatch each annotation symbol to the corresponding _dim_* method.
      def _add_annotations(container, back_def, bb, positions, annotations,
                           front_def: nil, foot_y: nil)
        annotations.each do |ann|
          send(:"_dim_#{ann}", container, back_def, bb, positions,
               front_def: front_def, foot_y: foot_y)
        end
      end

      # ── Dimension methods ─────────────────────────────────────────────────
      #
      # All share the signature (container, back_def, bb, positions).
      # In the left view: original Z → container Y, original Y → container -X.
      #   container_x = -y + lx + cy
      #   container_y = z  - cz

      # Vertical: ground → top of big pillow (seat), left of the left view.
      def _dim_seat_height(container, back_def, bb, positions, front_def: nil, foot_y: nil)
        lx = positions[:left][0]
        l  = bb.max.y - bb.min.y
        cz = bb.center.z

        pillow_bb  = _big_pillow_bounds(back_def)
        seat_top_z = pillow_bb ? pillow_bb.max.z : bb.max.z

        left_edge_x = lx - l / 2.0

        _add_dimension(
          container,
          Geom::Point3d.new(left_edge_x, bb.min.z - cz,  0),
          Geom::Point3d.new(left_edge_x, seat_top_z - cz, 0),
          Geom::Vector3d.new(-DIM_OFFSET, 0, 0)
        )
      end

      # Horizontal: full bed length, bottom of the left view, offset down.
      def _dim_bed_length(container, _back_def, bb, positions, front_def: nil, foot_y: nil)
        lx  = positions[:left][0]
        l   = bb.max.y - bb.min.y
        cz  = bb.center.z
        gnd = bb.min.z - cz

        _add_dimension(
          container,
          Geom::Point3d.new(lx - l / 2.0, gnd, 0),
          Geom::Point3d.new(lx + l / 2.0, gnd, 0),
          Geom::Vector3d.new(0, -DIM_OFFSET, 0)
        )
      end

      # Horizontal: big pillow (seat) length only, top of pillow in left view, offset up.
      # Used in the retracted variant where only the big pillow is flat on the slats.
      def _dim_pillow_length(container, back_def, bb, positions, front_def: nil, foot_y: nil)
        lx = positions[:left][0]
        cy = bb.center.y
        cz = bb.center.z

        pillow_bb = _big_pillow_bounds(back_def)
        return unless pillow_bb

        seat_top_y = pillow_bb.max.z - cz
        pillow_x1  = lx + cy - pillow_bb.min.y   # head end
        pillow_x2  = lx + cy - pillow_bb.max.y   # foot end

        _add_dimension(
          container,
          Geom::Point3d.new(pillow_x1, seat_top_y, 0),
          Geom::Point3d.new(pillow_x2, seat_top_y, 0),
          Geom::Vector3d.new(0, DIM_OFFSET, 0)
        )
      end

      # Horizontal: full bed-of-pillows length (big + all smalls), top of pillow in
      # left view, offset up.  Used in the extended variant where smalls live on the
      # front frame — equals usable_length_extended (2000 mm in default config).
      def _dim_pillows_length(container, back_def, bb, positions, front_def: nil, foot_y: nil)
        lx = positions[:left][0]
        cy = bb.center.y
        cz = bb.center.z

        pillow_bb = _big_pillow_bounds(back_def)
        return unless pillow_bb

        seat_top_y = pillow_bb.max.z - cz

        min_y, max_y = _pillows_y_extent(back_def, front_def, foot_y)
        return unless min_y && max_y

        head_x = lx + cy - min_y
        foot_x = lx + cy - max_y

        _add_dimension(
          container,
          Geom::Point3d.new(head_x, seat_top_y, 0),
          Geom::Point3d.new(foot_x, seat_top_y, 0),
          Geom::Vector3d.new(0, DIM_OFFSET, 0)
        )
      end

      # Horizontal: outer bed width, bottom of the front view, offset down.
      # Front view: R_z(180°)·R_x(90°) maps original X → -X, so width is
      # symmetric around x=0: -w/2 … +w/2.
      def _dim_bed_width(container, _back_def, bb, _positions, front_def: nil, foot_y: nil)
        w = bb.max.x - bb.min.x
        h = bb.max.z - bb.min.z

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
      # in the definition's local space (= pair-local space, back is at origin).
      def _big_pillow_bounds(back_def)
        inst = back_def.entities.find do |e|
          (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
            e.name == 'EB | pillow | big'
        end
        inst&.bounds
      end

      # Returns [min_y, max_y] in pair-local space across all pillows in both
      # back_def (offset 0) and front_def (offset foot_y).  When front_def or
      # foot_y is nil only the back pillows are considered.
      def _pillows_y_extent(back_def, front_def, foot_y)
        min_y = nil
        max_y = nil

        _each_pillow_entity(back_def) do |e|
          b = e.bounds
          min_y = min_y ? [min_y, b.min.y].min : b.min.y
          max_y = max_y ? [max_y, b.max.y].max : b.max.y
        end

        if front_def && foot_y
          _each_pillow_entity(front_def) do |e|
            b = e.bounds
            min_y = min_y ? [min_y, b.min.y + foot_y].min : b.min.y + foot_y
            max_y = max_y ? [max_y, b.max.y + foot_y].max : b.max.y + foot_y
          end
        end

        [min_y, max_y]
      end

      # Yields every direct child of +def_+ whose name matches PILLOW_NAME_RE.
      def _each_pillow_entity(def_, &block)
        def_.entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next unless e.name.match?(Config::PILLOW_NAME_RE)

          block.call(e)
        end
      end

      # 6 rotations that bring each face of the bed to face +Z (visible from top).
      #
      # Coordinate convention: +Y = head→foot, +X = left→right, +Z = up.
      #
      #   :front   R_z(180°)·R_x(+90°)  +Y face (foot end) → +Z, legs down
      #   :back    R_x(−90°)             −Y face (head end) → +Z
      #   :right   R_z(−90°)·R_y(−90°)  +X face (right)    → +Z, legs down
      #   :left    R_z(+90°)·R_y(+90°)  −X face (left)     → +Z, legs down
      #   :plan    identity              +Z face (top)       → +Z
      #   :bottom  R_x(180°)            −Z face (bottom)    → +Z
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
      #   right / left : L × H   (length runs along X after ±90° Z correction)
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
        l  = bb.max.y - bb.min.y   # bed length
        h  = bb.max.z - bb.min.z   # bed height

        {
          front:  [0,                                  0                      ],
          plan:   [0,                                  h / 2.0 + g + l / 2.0 ],
          bottom: [0,                                -(h / 2.0 + g + l / 2.0)],
          right:  [ w / 2.0 + hg + h / 2.0,           0                      ],
          left:   [-(w / 2.0 + hg + h / 2.0),         0                      ],
          back:   [ w / 2.0 + hg + h + hg + h / 2.0,  0                      ]
        }
      end

      # Transform (in container local space) that rotates the pair so a face
      # points up, then centres it at (layout_x, layout_y).
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
