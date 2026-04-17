# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Axis-aligned box face in **part local space** (see `SketchUpRenderer#_add_box`:
    # box spans [0,dx]×[0,dy]×[0,dz] before the part group's translation).
    #
    # UV origin for offsets is the **min corner** of that face in local coordinates:
    #   :min_x → (0,0,0),  u = +Y along the face, v = +Z
    #   :max_x → (dx,0,0), u = +Y, v = +Z
    #   :min_y → (0,0,0),  u = +X, v = +Z
    #   :max_y → (0,dy,0), u = +X, v = +Z
    #   :min_z → (0,0,0),  u = +X, v = +Y
    #   :max_z → (0,0,dz), u = +X, v = +Y
    #
    # +u+ and +v+ are SketchUp lengths (use `.mm`). By default the screw follows the face
    # **outward normal** (head on the outer side, shaft along −normal into the host).
    # Optional pocket tilt (`ScrewPlacement` + `SketchUpRenderer#_apply_pocket_tilt_outward!`)
    # rotates the shaft in the (normal, tangent) plane — e.g. sister tie :max_z into slats above.
    module BoxFace
      unless const_defined?(:ALL)
        ALL = %i[min_x max_x min_y max_y min_z max_z].freeze
      end
    end

    # Tangent on the box face for pocket tilt (part-local, axis-aligned; see `BoxFace` UV table).
    module PocketTiltToward
      unless const_defined?(:ALL)
        ALL = %i[pos_u neg_u pos_v neg_v].freeze
      end
    end

    # Declarative screw: references a part by Outliner name and a face + 2D offset.
    class ScrewPlacement
      attr_reader :name, :host_name, :face, :u, :v, :spec_id, :shaft_length_index,
                  :pocket_tilt_from_normal_deg, :pocket_tilt_toward, :pocket_away_from_host

      # @param pocket_tilt_from_normal_deg [Float] angle (degrees) between the screw **shaft**
      #   (into the joint) and the **face outward normal** after applying `pocket_away_from_host`
      #   base axis. 0 = perpendicular (default). Typical pocket jig ≈ 15.
      # @param pocket_tilt_toward [Symbol] one of `PocketTiltToward::ALL` — in-plane direction
      #   the shaft leans from the base axis (see `BoxFace` u/v mapping).
      # @param pocket_away_from_host [Boolean] if true, shaft runs **into the mate across the face**
      #   (negates face outward when tilt is 0; with tilt > 0, the tilted base uses +outward first).
      #   Example: :max_z on a beam under a slat — head beam-side, shaft +Z into slat. If false,
      #   default is head on the air side, shaft into the host solid.
      def initialize(name, host_name:, face:, u:, v:, spec_id:, shaft_length_index: 0,
                     pocket_tilt_from_normal_deg: 0, pocket_tilt_toward: :pos_v,
                     pocket_away_from_host: false)
        @name = name.to_s.freeze
        @host_name = host_name.to_s.freeze
        @face = face
        @u = u
        @v = v
        @spec_id = spec_id
        @shaft_length_index = shaft_length_index
        @pocket_tilt_from_normal_deg = pocket_tilt_from_normal_deg.to_f
        @pocket_tilt_toward = pocket_tilt_toward.to_sym
        @pocket_away_from_host = pocket_away_from_host ? true : false
        raise ArgumentError, "unknown face #{face.inspect}" unless BoxFace::ALL.include?(face)
        unless PocketTiltToward::ALL.include?(@pocket_tilt_toward)
          raise ArgumentError, "unknown pocket_tilt_toward #{@pocket_tilt_toward.inspect}"
        end
      end
    end

    # Nominal wood screw for preview: diameter, shaft length(s) from Config, head + countersink.
    class ScrewSpec
      attr_reader :id, :shaft_diameter, :shaft_lengths, :head_diameter, :head_height,
                  :countersink_diameter, :countersink_depth

      def initialize(id, shaft_diameter:, shaft_lengths:, head_diameter:, head_height:,
                     countersink_diameter:, countersink_depth:)
        @id = id
        @shaft_diameter = shaft_diameter
        @shaft_lengths = shaft_lengths.freeze
        @head_diameter = head_diameter
        @head_height = head_height
        @countersink_diameter = countersink_diameter
        @countersink_depth = countersink_depth
      end

      def shaft_length_at(index)
        @shaft_lengths.fetch(index)
      end
    end
  end
end
