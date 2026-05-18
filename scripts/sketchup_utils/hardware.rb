# frozen_string_literal: true

# Generic hardware value objects for SketchupUtils::PartCatalog — screws and
# their geometric placement on a host part's box face. No SketchUp references.

module Timmerman
  module SketchupUtils
    module Hardware
      # Axis-aligned box face in **part local space**. The box spans
      # [0,dx]×[0,dy]×[0,dz] before the part group's translation.
      #
      # UV origin for offsets is the min corner of the face in local coords:
      #   :min_x → (0,0,0),   u = +Y along face, v = +Z
      #   :max_x → (dx,0,0),  u = +Y,           v = +Z
      #   :min_y → (0,0,0),   u = +X,           v = +Z
      #   :max_y → (0,dy,0),  u = +X,           v = +Z
      #   :min_z → (0,0,0),   u = +X,           v = +Y
      #   :max_z → (0,0,dz),  u = +X,           v = +Y
      module BoxFace
        ALL = %i[min_x max_x min_y max_y min_z max_z].freeze
      end

      # In-plane tangent on a box face, for pocket-tilt direction. See
      # +BoxFace+ UV mapping; each face exposes u/v axes.
      module PocketTiltToward
        ALL = %i[pos_u neg_u pos_v neg_v].freeze
      end

      # Nominal wood-screw geometry: diameter, shaft length(s), head + countersink.
      # +shaft_lengths+ is an array so one spec can model multiple stock screw lengths
      # (indexed via +ScrewPlacement#shaft_length_index+).
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

      # Declarative screw placement: references a host part by Outliner name and
      # a face + 2D offset on that face. Carries a concrete +ScrewSpec+ so the
      # renderer never needs a spec catalog. +spec_id+ (delegated to spec.id)
      # remains available for stock-plan tallying.
      class ScrewPlacement
        attr_reader :name, :host_name, :face, :u, :v, :spec, :shaft_length_index,
                    :pocket_tilt_from_normal_deg, :pocket_tilt_toward, :pocket_away_from_host

        # @param pocket_tilt_from_normal_deg [Float] angle between shaft and face
        #   outward normal after +pocket_away_from_host+ base axis is applied.
        #   0 = perpendicular (default); ~15 is a typical pocket jig.
        # @param pocket_tilt_toward [Symbol] in-plane direction the shaft leans
        #   from the base axis (one of +PocketTiltToward::ALL+).
        # @param pocket_away_from_host [Boolean] if true, shaft runs into the
        #   mate across the face (negates face outward when tilt is 0).
        def initialize(name, host_name:, face:, u:, v:, spec:, shaft_length_index: 0,
                       pocket_tilt_from_normal_deg: 0, pocket_tilt_toward: :pos_v,
                       pocket_away_from_host: false)
          @name = name.to_s.freeze
          @host_name = host_name.to_s.freeze
          @face = face
          @u = u
          @v = v
          @spec = spec
          @shaft_length_index = shaft_length_index
          @pocket_tilt_from_normal_deg = pocket_tilt_from_normal_deg.to_f
          @pocket_tilt_toward = pocket_tilt_toward.to_sym
          @pocket_away_from_host = pocket_away_from_host ? true : false

          raise ArgumentError, "unknown face #{face.inspect}" unless BoxFace::ALL.include?(face)
          unless PocketTiltToward::ALL.include?(@pocket_tilt_toward)
            raise ArgumentError, "unknown pocket_tilt_toward #{@pocket_tilt_toward.inspect}"
          end
        end

        def spec_id = @spec.id
      end
    end
  end
end
