# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Adds SketchUp DimensionLinear annotations to the extended-bed pair.
    # All dimensions are placed on the same layer as the bed geometry.
    #
    # Annotates:
    #   — Bed width (outer_width, along X)
    #   — Extended length (head plank face to foot plank face, along Y)
    #   — Retracted length (same reference lines, retracted pair)
    #   — Slat run (back_slat_run_y, along Y)
    #   — Leg height (leg_height, along Z)
    #   — Beam section (beam_narrow and beam_wide, shown on a corner leg)
    #
    # Usage:
    #   dims = Dimensions.new(config, model)
    #   dims.annotate_extended_pair(back_group, front_group, layer:)
    #   dims.annotate_retracted_pair(back_group, layer:)
    class Dimensions
      DIM_OFFSET_SCALE = 0.15   # fraction of the dimension length used as leader offset

      def initialize(config, model)
        @config = config
        @model  = model
      end

      # Annotates the fully-extended pair: width, extended length, slat run, leg
      # height, and beam section on one corner leg.
      def annotate_extended_pair(back_group, front_group, layer: nil)
        entities = back_group.entities   # all dims go inside the back root group
        c        = @config
        ox       = back_group.transformation.origin.x   # world X offset of back root

        _dim_width(entities,    c, layer)
        _dim_extended_length(entities, back_group, front_group, c, layer)
        _dim_slat_run(entities, c, layer)
        _dim_leg_height(entities, c, layer)
        _dim_beam_section(entities, c, layer)
      end

      # Annotates the retracted pair: retracted length.
      def annotate_retracted_pair(back_group, layer: nil)
        _dim_retracted_length(back_group.entities, @config, layer)
      end

      private

      # ── Dimension helpers ─────────────────────────────────────────────────

      # Adds a DimensionLinear with free-floating anchor points (no attached entity).
      # +pt1+, +pt2+ are Geom::Point3d in the target entities' local space.
      # +offset_vec+ is the leader offset direction and magnitude.
      def _add_dim(entities, pt1, pt2, offset_vec, layer: nil)
        d = entities.add_dimension_linear([nil, pt1], [nil, pt2], offset_vec)
        d.layer = layer if layer
        d
      end

      # ── Individual dimension types ────────────────────────────────────────

      # Bed outer width along X, shown on the headward face of the head end beam.
      def _dim_width(entities, c, layer)
        z_top = c.z_slat_bottom + c.beam_z
        y_dim = 0   # headward face of head end beam
        pt1   = Geom::Point3d.new(0,            y_dim, z_top)
        pt2   = Geom::Point3d.new(c.outer_width, y_dim, z_top)
        _add_dim(entities, pt1, pt2,
                 Geom::Vector3d.new(0, -c.outer_width * DIM_OFFSET_SCALE, 0),
                 layer: layer)
      end

      # Extended length: from headward face of head end beam to footward face of front
      # foot end beam.  pt2 is in the back-frame's local space: foot_world_y − 0 = foot_y.
      def _dim_extended_length(entities, back_group, front_group, c, layer)
        foot_world_y = front_group.transformation.origin.y
        back_world_y = back_group.transformation.origin.y    # 0 for back frame
        foot_local_y = foot_world_y - back_world_y           # in back local space

        z_mid = c.z_slat_bottom / 2.0
        x_dim = c.outer_width + c.outer_width * DIM_OFFSET_SCALE
        pt1   = Geom::Point3d.new(x_dim, 0,                          z_mid)
        pt2   = Geom::Point3d.new(x_dim, foot_local_y - c.beam_y,    z_mid)
        _add_dim(entities, pt1, pt2,
                 Geom::Vector3d.new(c.outer_width * DIM_OFFSET_SCALE, 0, 0),
                 layer: layer)
      end

      # Back slat run along Y (from end-beam face at y=0 to slat tip at BACK_SLAT_RUN_Y+BEAM_Y).
      def _dim_slat_run(entities, c, layer)
        z_top = c.z_slat_top
        x_dim = c.outer_width / 2.0
        pt1   = Geom::Point3d.new(x_dim, c.beam_y,                       z_top)
        pt2   = Geom::Point3d.new(x_dim, c.beam_y + c.back_slat_run_y,   z_top)
        _add_dim(entities, pt1, pt2,
                 Geom::Vector3d.new(0, 0, c.slat_dz * DIM_OFFSET_SCALE),
                 layer: layer)
      end

      # Leg height: floor (z=0) to top of corner leg (z=outer_corner_leg_height).
      def _dim_leg_height(entities, c, layer)
        x_leg  = 0
        y_leg  = -c.plank_thickness
        offset = -c.leg_x * DIM_OFFSET_SCALE
        pt1    = Geom::Point3d.new(x_leg + offset, y_leg, 0)
        pt2    = Geom::Point3d.new(x_leg + offset, y_leg, c.outer_corner_leg_height)
        _add_dim(entities, pt1, pt2,
                 Geom::Vector3d.new(offset, 0, 0),
                 layer: layer)
      end

      # Beam section: narrow (44 mm) and wide (69 mm) shown on the -X corner leg face.
      def _dim_beam_section(entities, c, layer)
        y_leg  = -c.plank_thickness
        x_face = 0
        z_base = 0
        offset = -(c.outer_width * DIM_OFFSET_SCALE * 0.5)

        # Narrow edge (44 mm) along X face of corner leg
        pt1n = Geom::Point3d.new(x_face, y_leg,              z_base)
        pt2n = Geom::Point3d.new(x_face, y_leg + c.beam_narrow, z_base)
        _add_dim(entities, pt1n, pt2n,
                 Geom::Vector3d.new(offset, 0, 0),
                 layer: layer)

        # Wide edge (69 mm) along Z on the same leg face
        pt1w = Geom::Point3d.new(x_face + offset, y_leg, z_base)
        pt2w = Geom::Point3d.new(x_face + offset, y_leg, z_base + c.beam_wide)
        _add_dim(entities, pt1w, pt2w,
                 Geom::Vector3d.new(offset, 0, 0),
                 layer: layer)
      end

      # Retracted length: head end beam face (y=0) to retracted foot position.
      def _dim_retracted_length(entities, c, layer)
        z_mid = c.z_slat_bottom / 2.0
        x_dim = c.outer_width + c.outer_width * DIM_OFFSET_SCALE
        # In the retracted back frame local space, foot world Y is retracted_foot_world_y;
        # front frame translation is retracted_foot_world_y, so slat end in back local space:
        y_ret_end = c.length_retracted + c.beam_narrow
        pt1 = Geom::Point3d.new(x_dim, 0,         z_mid)
        pt2 = Geom::Point3d.new(x_dim, y_ret_end, z_mid)
        _add_dim(entities, pt1, pt2,
                 Geom::Vector3d.new(c.outer_width * DIM_OFFSET_SCALE, 0, 0),
                 layer: layer)
      end
    end
  end
end
