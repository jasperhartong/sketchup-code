# frozen_string_literal: true

# ONLY USE beams that are extrusions of 44×69 — orientation free: one rectangular face must be
# 44 mm × 69 mm; the third dimension is only the extrusion length (any value).

# Extendable interlocking-slats bed: back (head) frame + front (foot) frame.
# SketchUp uses inches internally; dimensions below use .mm.
#
# Design is driven by actual section size and cut lengths — not nominal 800/2000/etc.
# Tune: BEAM_NARROW/WIDE, comb counts, SLAT_GAP, SLAT_LENGTH, OVERLAP_WHEN_EXTENDED,
# TOP_OF_SLATS_Z (mattress support), SIDE_INSET.
#
# Coordinates: +Y head → foot (extension). +Z up. Slats run parallel to Y.
# create always places two full copies side by side along +X: extended and retracted.

module Timmerman
  module ExtendableBed
    LAYER_NAME = 'EB_ExtendableBed'

    # --- Stock section (edit to match your timber) ---
    BEAM_NARROW = 44.mm
    BEAM_WIDE = 69.mm

    # Sliding clearance between neighbours along X (kerf + play)
    SLAT_GAP = 3.mm

    # Comb: back “teeth” + front “teeth” (front sits in gaps of back)
    # 9 + 8 → outer width 17×44 + 16×3 = 796 mm (was 10+9 → 890 mm)
    BACK_SLAT_COUNT = 9
    FRONT_SLAT_COUNT = 8

    # Optional flush inset from outer X for legs/slats (0 = comb fills full width)
    SIDE_INSET = 0.mm

    # Slats: narrow edge along bed width (X), wide edge vertical (Z) — stiffer in bending
    SLAT_DX = BEAM_NARROW
    SLAT_DZ = BEAM_WIDE

    # End beams: narrow along run (Y), wide vertical (Z)
    BEAM_Y = BEAM_NARROW
    BEAM_Z = BEAM_WIDE

    # Head/foot caps: same sawn face as other beams (BEAM_Y × BEAM_Z = 44 × 69 in Y × Z); full width X. Depth along Y is BEAM_Y.

    # Leg posts under end beams — 90° vs old layout: wide along X (across slats), narrow along Y
    # (same as slats: 44 mm parallel to slat run, 69 mm across the comb)
    LEG_X = BEAM_WIDE
    LEG_Y = BEAM_NARROW

    # --- Length chain (from cut length + overlap, not a guessed “2000”) ---
    # Each slat stick length after cut (along Y)
    SLAT_LENGTH = 1100.mm
    # Overlap of the two slat runs when the bed is fully open (structural bridge)
    OVERLAP_WHEN_EXTENDED = 200.mm

    # Outer span head → foot when open: two slat runs minus one overlap
    LENGTH_EXTENDED = (2 * SLAT_LENGTH) - OVERLAP_WHEN_EXTENDED

    # Outer span when nested: head end depth (BEAM_Y) + slat run
    LENGTH_RETRACTED = SLAT_LENGTH + BEAM_Y

    # Retracted front-group foot Y: offset + narrow face (BEAM_NARROW) so foot legs sit past the
    # back middle legs instead of sharing the same Y band as BEAM_Y-deep corner legs.
    RETRACTED_FOOT_WORLD_Y = LENGTH_RETRACTED + BEAM_NARROW

    # --- Height chain: top of slats is the only vertical “target”; leg is the remainder ---
    # +20 mm vs 400 so caps use full BEAM_Z in Z (sawn 44×69 face); keeps z_leg_top / leg_height unchanged.
    TOP_OF_SLATS_Z = 420.mm

    N_SLATS_X = BACK_SLAT_COUNT + FRONT_SLAT_COUNT
    GAPS_ALONG_X = N_SLATS_X - 1

    OUTER_WIDTH =
      (2 * SIDE_INSET) +
      (N_SLATS_X * SLAT_DX) +
      (GAPS_ALONG_X * SLAT_GAP)

    # Gap between the extended and retracted copies along +X (outside edge to outside edge)
    PAIR_GAP_X = 300.mm

    GROUP_EXT_BACK = 'EB_Ext_Back'
    GROUP_EXT_FRONT = 'EB_Ext_Front'
    GROUP_RET_BACK = 'EB_Ret_Back'
    GROUP_RET_FRONT = 'EB_Ret_Front'

    EB_GROUP_NAME_RE = /\AEB_(Ext|Ret)_(Back|Front)\z/
    # Single-pair bed roots (cleared together with EB_Ext_* / EB_Ret_*).
    EB_SINGLE_PAIR_ROOTS = %w[EB_Back EB_Front].freeze

    # Unqualified mid behind-leg outliner names (current geometry uses HEADWARD_BEHIND_LEG_MID_*).
    # Purged recursively on clear so stray copies outside top-level EB roots are removed.
    BEHIND_LEG_MID_UNQUALIFIED_NAMES = %w[
      EB | beam | behind leg | mid -X
      EB | beam | behind leg | mid +X
    ].freeze
    HEADWARD_BEHIND_LEG_MID_NEG_X = 'EB | beam | behind leg | mid -X | headward'
    HEADWARD_BEHIND_LEG_MID_POS_X = 'EB | beam | behind leg | mid +X | headward'

    # Beams + legs only (excludes slats); used for overlap checks between structural solids.
    EB_SOLID_NAME_RE = /\AEB \| (beam|leg) \|/

    module_function

    # Always use model root for EB geometry. +active_entities+ follows edit context; mixing it with
    # +clear+ left top-level beds in place while nesting new runs (duplicate roots, false overlaps).
    def placement_entities(model)
      model.entities
    end

    # SketchUp raises if you erase an entity on the active edit path; pop all nested edits first.
    def exit_edit_context!(model)
      while model.close_active
      end
    end

    # Erase nested groups by exact name (Groups only — skips ComponentInstance definitions).
    def purge_named_groups_recursive(entities, names_to_erase)
      entities.to_a.each do |e|
        next unless e.valid?
        next unless e.is_a?(Sketchup::Group)

        purge_named_groups_recursive(e.entities, names_to_erase)
        e.erase! if names_to_erase.include?(e.name)
      end
    end

    def z_slat_bottom
      TOP_OF_SLATS_Z - SLAT_DZ
    end

    # Slat boxes only: one BEAM_Z lower than the nominal chain so slats sit flush with the leg
    # top crossbeam; legs / cap / head-foot end beams keep the chain from TOP_OF_SLATS_Z.
    def z_slats_box_bottom
      z_slat_bottom - BEAM_Z
    end

    def z_beam_bottom
      z_slat_bottom - BEAM_Z
    end

    def z_leg_top
      z_beam_bottom - BEAM_Z
    end

    def leg_height
      z_leg_top
    end

    # Mid-run legs share X with outer comb columns; tops must stop at sister-beam bottom (no Z overlap).
    def mid_run_leg_height(z_slats)
      z_slats - BEAM_Z
    end

    def outer_width
      OUTER_WIDTH
    end

    def ensure_layer(model)
      layer = model.layers[LAYER_NAME]
      layer ||= model.layers.add(LAYER_NAME)
      layer
    end

    ATTR_DICT = 'Timmerman::ExtendableBed'

    # Millimetres — all stock checks and usage tallies are metric (SU stores lengths internally as Length).
    BEAM_SECTION_TOL_MM = 0.01

    def reset_beam_stock_usage!
      @beam_stock_extrusion_m = 0.0
      @beam_stock_piece_count = 0
    end

    def beam_stock_extrusion_m
      @beam_stock_extrusion_m ||= 0.0
    end

    def beam_stock_piece_count
      @beam_stock_piece_count ||= 0
    end

    def stock_section_match?(len)
      v = len.to_mm.abs
      n = BEAM_NARROW.to_mm
      w = BEAM_WIDE.to_mm
      (v - n).abs < BEAM_SECTION_TOL_MM || (v - w).abs < BEAM_SECTION_TOL_MM
    end

    # One prism dimension is extrusion length; the other two must be BEAM_NARROW × BEAM_WIDE (order free).
    def extrusion_length_mm(dx, dy, dz)
      dims = [dx, dy, dz]
      unless dims.count { |d| stock_section_match?(d) } == 2
        got = dims.map { |d| format('%.2f mm', d.to_mm) }.join(', ')
        raise ArgumentError,
              "EB stock beam: need two section sides (#{BEAM_NARROW.to_mm.round(2)} × #{BEAM_WIDE.to_mm.round(2)} mm), got (#{got})"
      end

      long = dims.find { |d| !stock_section_match?(d) }
      long = long.to_mm.abs
      raise ArgumentError, 'EB stock beam: extrusion length must be > 0' if long <= BEAM_SECTION_TOL_MM

      long
    end

    # All solid stock (legs, slats, caps, sisters, ties) goes through here — validates 44×69 extrusion and tallies metres.
    def add_stock_beam(parent_entities, name, x, y, z, dx, dy, dz, note: nil, layer: nil, count_usage: true)
      extrusion_mm = extrusion_length_mm(dx, dy, dz)
      if count_usage
        @beam_stock_extrusion_m = (beam_stock_extrusion_m + (extrusion_mm / 1000.0))
        @beam_stock_piece_count = beam_stock_piece_count + 1
      end
      add_named_part(parent_entities, name, x, y, z, dx, dy, dz, note: note, layer: layer)
    end

    # Raw box in the given entities’ local space (used inside named wrappers).
    def add_box(entities, x, y, z, dx, dy, dz)
      pts = [
        Geom::Point3d.new(x, y, z),
        Geom::Point3d.new(x + dx, y, z),
        Geom::Point3d.new(x + dx, y + dy, z),
        Geom::Point3d.new(x, y + dy, z)
      ]
      f = entities.add_face(pts)
      f.reverse! if f.normal.z < 0
      f.pushpull(dz)
    end

    # Nested group: shows +name+ in Outliner; optional +note+ on ATTR_DICT (Entity Info → second tab).
    # Use +add_stock_beam+ for all 44×69 stock; this is the low-level primitive only.
    def add_named_part(parent_entities, name, x, y, z, dx, dy, dz, note: nil, layer: nil)
      g = parent_entities.add_group
      g.name = name
      g.layer = layer if layer
      g.set_attribute(ATTR_DICT, 'note', note) if note && !note.to_s.empty?
      add_box(g.entities, 0, 0, 0, dx, dy, dz)
      g.transformation = Geom::Transformation.translation([x, y, z])
      g
    end

    def slat_starts_along_x
      margin = SIDE_INSET
      step = 2 * (SLAT_DX + SLAT_GAP)
      back = (0...BACK_SLAT_COUNT).map { |k| margin + k * step }
      front = (0...FRONT_SLAT_COUNT).map { |j| margin + (SLAT_DX + SLAT_GAP) + j * step }
      [back, front]
    end

    # Left/right comb slats (min and max X start); all slats share SLAT_DX.
    def outermost_comb_slat_x_starts
      back_xs, front_xs = slat_starts_along_x
      merged = back_xs + front_xs
      [merged.min, merged.max]
    end

    # Fixed (back) frame only: two beams, same plan as the outermost slats, stacked under them (BEAM_Z).
    def add_beams_below_outermost_slats_back(entities, z_slats, layer: nil)
      z_lo = z_slats - BEAM_Z
      y0 = BEAM_Y
      lo_x, hi_x = outermost_comb_slat_x_starts
      add_stock_beam(
        entities,
        'EB | beam | sister | outer -X',
        lo_x, y0, z_lo, SLAT_DX, SLAT_LENGTH, BEAM_Z,
        layer: layer,
        note: 'Sister under outermost comb slat at -X; same XY as that slat; BEAM_Z thick; top flush with slat bottom.'
      )
      add_stock_beam(
        entities,
        'EB | beam | sister | outer +X',
        hi_x, y0, z_lo, SLAT_DX, SLAT_LENGTH, BEAM_Z,
        layer: layer,
        note: 'Sister under outermost comb slat at +X; same XY as that slat; BEAM_Z thick; top flush with slat bottom.'
      )
    end

    # Four 44×69 prisms, all inside the slat frame in Y:
    # Head legs → beam +Y of leg (y = LEG_Y). Mid legs → beam headward of y = mid_y0; plan depth along Y is LEG_X,
    # so origin y = mid_y0 − LEG_X gives y ∈ [mid_y0 − LEG_X, mid_y0] (flush with leg, no overlap with [mid_y0, mid_y0 + LEG_Y]).
    def add_beams_behind_back_legs(entities, mid_y0, lh_corner, lh_mid, layer: nil)
      w = outer_width
      y_behind_head = LEG_Y
      y_behind_mid = mid_y0 - LEG_X
      # Plan: narrow LEG_Y along X (flush to outer ±X), LEG_X along +Y so the 69 mm face is on the outer YZ plane.
      note_head = '44×69 plan (LEG_Y×LEG_X in X×Y), extruded Z; +Y of head leg; 69 mm along Y on outer ±X face.'
      note_mid = '44×69 plan (LEG_Y×LEG_X in X×Y), extruded Z; −Y of mid leg, headward; 69 mm along Y on outer ±X face.'
      add_stock_beam(
        entities, 'EB | beam | behind leg | head -X',
        0, y_behind_head, 0, LEG_Y, LEG_X, lh_corner,
        layer: layer, note: note_head
      )
      add_stock_beam(
        entities, 'EB | beam | behind leg | head +X',
        w - LEG_Y, y_behind_head, 0, LEG_Y, LEG_X, lh_corner,
        layer: layer, note: note_head
      )
      add_stock_beam(
        entities, HEADWARD_BEHIND_LEG_MID_NEG_X,
        0, y_behind_mid, 0, LEG_Y, LEG_X, lh_mid,
        layer: layer, note: note_mid
      )
      add_stock_beam(
        entities, HEADWARD_BEHIND_LEG_MID_POS_X,
        w - LEG_Y, y_behind_mid, 0, LEG_Y, LEG_X, lh_mid,
        layer: layer, note: note_mid
      )
    end

    # X-only gap between outer sister beams; on mid-run legs (same Y depth as legs, same Z stack as sisters).
    def add_mid_tie_beam_between_sisters(entities, mid_y0, lh_mid, layer: nil)
      lo_x, hi_x = outermost_comb_slat_x_starts
      x1 = lo_x + SLAT_DX
      span_x = hi_x - x1
      return if span_x <= 0

      add_stock_beam(
        entities,
        'EB | beam | mid tie | between sisters',
        x1, mid_y0, lh_mid, span_x, LEG_Y, BEAM_Z,
        layer: layer,
        note: 'Rests on EB | leg | mid run | -X/+X; spans X from inner face of outer -X sister to outer +X sister; Z matches sisters.'
      )
    end

    # Axis-aligned overlap in world space (SketchUp inches). Touching faces do not count.
    def aabb_overlap?(bb1, bb2)
      bb1.max.x > bb2.min.x && bb2.max.x > bb1.min.x &&
        bb1.max.y > bb2.min.y && bb2.max.y > bb1.min.y &&
        bb1.max.z > bb2.min.z && bb2.max.z > bb1.min.z
    end

    # World AABB for a group. SketchUp Group#bounds corners are in the *parent* coordinate system
    # (Drawingelement#bounds), not the group's local system — do not multiply by group.transformation.
    def world_bounds_for_group(group, parent_world_tr)
      bb = group.bounds
      wb = Geom::BoundingBox.new
      8.times { |i| wb.add(bb.corner(i).transform(parent_world_tr)) }
      wb
    end

    def collect_eb_solids_world(entities, parent_world_tr, out)
      entities.grep(Sketchup::Group).each do |g|
        next unless g.valid?

        if EB_SOLID_NAME_RE.match?(g.name)
          out << { name: g.name, bb: world_bounds_for_group(g, parent_world_tr), eid: g.entityID }
        end
        collect_eb_solids_world(g.entities, parent_world_tr * g.transformation, out)
      end
    end

    def eb_root_groups(model)
      model.entities.grep(Sketchup::Group).select do |g|
        EB_GROUP_NAME_RE.match?(g.name) || EB_SINGLE_PAIR_ROOTS.include?(g.name)
      end
    end

    # Pairs of named beam/leg groups whose world axis-aligned bounds intersect, scoped per top-level EB root.
    def overlapping_eb_solid_pairs(model = Sketchup.active_model)
      pairs = []
      eb_root_groups(model).each do |root|
        next unless root.valid?

        items = []
        collect_eb_solids_world(root.entities, root.transformation, items)
        (0...items.size).each do |i|
          ((i + 1)...items.size).each do |j|
            a = items[i]
            b = items[j]
            next if a[:eid] == b[:eid]

            pairs << { root: root.name, a: a[:name], b: b[:name] } if aabb_overlap?(a[:bb], b[:bb])
          end
        end
      end
      pairs
    end

    # Prints a one-line summary; returns the overlap list (empty = OK).
    def validate_eb_solids(model = Sketchup.active_model)
      pairs = overlapping_eb_solid_pairs(model)
      if pairs.empty?
        puts '[EB validate] OK — no beam/leg bounding-box overlaps within each EB root.'
      else
        puts "[EB validate] #{pairs.size} overlapping beam/leg pair(s):"
        pairs.each { |p| puts "  #{p[:root]}: #{p[:a]}  ⟷  #{p[:b]}" }
      end
      pairs
    end

    def clear(model = Sketchup.active_model)
      exit_edit_context!(model)
      roots = placement_entities(model)
      purge_named_groups_recursive(roots, BEHIND_LEG_MID_UNQUALIFIED_NAMES)
      to_erase = roots.grep(Sketchup::Group).select do |g|
        EB_GROUP_NAME_RE.match?(g.name) || EB_SINGLE_PAIR_ROOTS.include?(g.name)
      end
      to_erase.each(&:erase!)
    end

    def build_back_group(model, name:)
      layer = ensure_layer(model)
      g = placement_entities(model).add_group
      g.name = name
      g.layer = layer
      e = g.entities
      w = outer_width

      zb = z_beam_bottom
      z_slats = z_slats_box_bottom
      lh = leg_height
      lh_mid = mid_run_leg_height(z_slats)
      zlt = z_leg_top

      add_stock_beam(e, 'EB | leg | head | -X', 0, 0, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Corner leg at head (+Y end of back group), -X side.')
      add_stock_beam(e, 'EB | leg | head | +X', w - LEG_X, 0, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Corner leg at head (+Y end of back group), +X side.')

      mid_y0 = LENGTH_RETRACTED - LEG_Y
      add_stock_beam(e, 'EB | leg | mid run | -X', 0, mid_y0, 0, LEG_X, LEG_Y, lh_mid,
                     layer: layer,
                     note: 'Mid-span leg, -X; top flush with bottom of EB | beam | sister | outer -X (shorter than corner legs).')
      add_stock_beam(e, 'EB | leg | mid run | +X', w - LEG_X, mid_y0, 0, LEG_X, LEG_Y, lh_mid,
                     layer: layer,
                     note: 'Mid-span leg, +X; top flush with bottom of EB | beam | sister | outer +X.')

      # Inset copies flush on the inner ±X faces of the outer legs (same stock/heights) for extra stiffness.
      add_stock_beam(e, 'EB | leg | head | -X | inset', LEG_X, 0, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | head | -X, +X of its inner face.')
      add_stock_beam(e, 'EB | leg | head | +X | inset', w - (2 * LEG_X), 0, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | head | +X, −X of its inner face.')
      add_stock_beam(e, 'EB | leg | mid run | -X | inset', LEG_X, mid_y0, 0, LEG_X, LEG_Y, lh_mid,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | mid run | -X, +X of its inner face.')
      add_stock_beam(e, 'EB | leg | mid run | +X | inset', w - (2 * LEG_X), mid_y0, 0, LEG_X, LEG_Y, lh_mid,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | mid run | +X, −X of its inner face.')

      add_beams_behind_back_legs(e, mid_y0, lh, lh_mid, layer: layer)

      add_stock_beam(e, 'EB | beam | head | cap', 0, 0, zlt, w, BEAM_Y, BEAM_Z,
                     layer: layer,
                     note: 'Same stock face as end beam: full width × BEAM_Y × BEAM_Z (44×69 mm in Y×Z).')
      add_stock_beam(e, 'EB | beam | head | end', 0, 0, zb, w, BEAM_Y, BEAM_Z,
                     layer: layer,
                     note: 'Head end beam 44×69 mm (BEAM_Y × BEAM_Z); under cap.')

      back_xs, = slat_starts_along_x
      y0 = BEAM_Y
      back_xs.each_with_index do |x0, i|
        add_stock_beam(
          e,
          format('EB | slat | back | %d/%d', i + 1, BACK_SLAT_COUNT),
          x0, y0, z_slats, SLAT_DX, SLAT_LENGTH, SLAT_DZ,
          layer: layer,
          note: 'Back (fixed) comb tooth; interlocks with front slats when assembled.'
        )
      end

      add_beams_below_outermost_slats_back(e, z_slats, layer: layer)
      add_mid_tie_beam_between_sisters(e, mid_y0, lh_mid, layer: layer)

      g
    end

    def build_front_geometry(entities, layer: nil)
      w = outer_width
      zb = z_beam_bottom
      z_slats = z_slats_box_bottom
      lh = leg_height
      zlt = z_leg_top

      add_stock_beam(entities, 'EB | leg | foot | -X', 0, -BEAM_Y, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Corner leg at foot (-Y side of front group local coords), -X.')
      add_stock_beam(entities, 'EB | leg | foot | +X', w - LEG_X, -BEAM_Y, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Corner leg at foot, +X.')

      add_stock_beam(entities, 'EB | leg | foot | -X | inset', LEG_X, -BEAM_Y, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | foot | -X, +X of its inner face.')
      add_stock_beam(entities, 'EB | leg | foot | +X | inset', w - (2 * LEG_X), -BEAM_Y, 0, LEG_X, LEG_Y, lh,
                     layer: layer,
                     note: 'Inset strengthener; duplicate of EB | leg | foot | +X, −X of its inner face.')

      add_stock_beam(entities, 'EB | beam | foot | cap', 0, -BEAM_Y, zlt, w, BEAM_Y, BEAM_Z,
                     layer: layer,
                     note: 'Same stock face as end beam: full width × BEAM_Y × BEAM_Z (44×69 mm in Y×Z).')
      add_stock_beam(entities, 'EB | beam | foot | end', 0, -BEAM_Y, zb, w, BEAM_Y, BEAM_Z,
                     layer: layer,
                     note: 'Foot end beam 44×69 mm (BEAM_Y × BEAM_Z); under cap.')

      _, front_xs = slat_starts_along_x
      y1 = -BEAM_Y - SLAT_LENGTH
      front_xs.each_with_index do |x0, i|
        add_stock_beam(
          entities,
          format('EB | slat | front | %d/%d', i + 1, FRONT_SLAT_COUNT),
          x0, y1, z_slats, SLAT_DX, SLAT_LENGTH, SLAT_DZ,
          layer: layer,
          note: 'Front (sliding) comb tooth; sits in gaps of back slats.'
        )
      end
    end

    def build_front_group(model, name:, foot_world_y:, offset_x: 0)
      layer = ensure_layer(model)
      g = placement_entities(model).add_group
      g.name = name
      g.layer = layer
      build_front_geometry(g.entities, layer: layer)
      g.transformation = Geom::Transformation.translation([offset_x, foot_world_y, 0])
      g
    end

    def place_pair(model, offset_x:, foot_world_y:, back_name:, front_name:)
      b = build_back_group(model, name: back_name)
      b.transformation = Geom::Transformation.translation([offset_x, 0, 0])
      build_front_group(model, name: front_name, foot_world_y: foot_world_y, offset_x: offset_x)
    end

    def create(model = Sketchup.active_model)
      model.start_operation('Extendable bed', true)
      clear(model)
      reset_beam_stock_usage!
      w = outer_width
      gap = PAIR_GAP_X
      place_pair(
        model,
        offset_x: 0,
        foot_world_y: LENGTH_EXTENDED,
        back_name: GROUP_EXT_BACK,
        front_name: GROUP_EXT_FRONT
      )
      place_pair(
        model,
        offset_x: w + gap,
        foot_world_y: RETRACTED_FOOT_WORLD_Y,
        back_name: GROUP_RET_BACK,
        front_name: GROUP_RET_FRONT
      )
      model.commit_operation
      model.active_view.invalidate
      validate_eb_solids(model)
      m = beam_stock_extrusion_m
      n = beam_stock_piece_count
      puts format('[EB stock] %.3f m total extrusion length (%d prism pieces); two side-by-side pairs in model.',
                  m, n)
    end
  end
end
