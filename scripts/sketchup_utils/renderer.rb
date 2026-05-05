# frozen_string_literal: true

# Abstract Renderer interface consumed by SketchupUtils::PartRendering.
# Documented here as a Ruby module; concrete backends (e.g. SketchUpRenderer,
# ObjExporter, test double) provide implementations. Any object that responds
# to the methods below can be passed wherever a "renderer" is expected —
# duck-typed, no ancestor requirement.
#
# A renderer's unit of work is a "group": an opaque handle the renderer owns,
# created via `create_group`. Geometry / attributes / transforms are added to
# existing groups via further calls. Consumers never inspect the handle's
# internals — only hand it back to the renderer.

module Timmerman
  module SketchupUtils
    module Renderer
      # ── Scene graph ──────────────────────────────────────────────────────

      # Creates a new group named +name+ inside +parent+ (either a group handle
      # or the special symbol :root for the top-level scene). Returns a handle.
      def create_group(name, parent:, layer: nil)
        raise NotImplementedError
      end

      # Sets a group's world/local transform from a SketchupUtils::Transform.
      def set_group_transform(group, transform)
        raise NotImplementedError
      end

      # Sets a custom attribute on a group (used for notes etc.).
      def set_group_attribute(group, dict, key, value)
        raise NotImplementedError
      end

      # Returns the group's bounds min.z in SketchUp length units (for the
      # "lift upside-down root to z=0" trick). Optional on backends that don't
      # have bounds — the bed's upside-down placement uses it.
      def group_min_z(group)
        raise NotImplementedError
      end

      # ── Geometry primitives (local to a group) ───────────────────────────

      # Extrudes an axis-aligned box into a group.
      # +at+ and +size+ are 3-arrays of SketchUp Length values.
      def add_box(group, at:, size:)
        raise NotImplementedError
      end

      # Renders a screw body at +transform+ (world-space, pre-composed).
      # +spec+ is a SketchupUtils::Hardware::ScrewSpec. This stays a
      # renderer-level op because backends may mesh / primitive differently.
      def add_screw_body(parent_group, name:, transform:, spec:, shaft_length_index:, layer: nil)
        raise NotImplementedError
      end

      # Cuts countersink + through-hole on a host part group, following the
      # pre-tilted face geometry from SketchupUtils::PocketGeometry. Optional
      # on backends that don't subtract geometry (they may no-op and rely on
      # the screw body alone).
      def cut_pocket_and_hole(host_group, geo:, spec:)
        raise NotImplementedError
      end

      # ── Styling ──────────────────────────────────────────────────────────

      def ensure_layer(name)
        raise NotImplementedError
      end

      # Paint every face of +group+ (recursively) with +[r,g,b]+ 0-255.
      # +skip_name_re+ optionally excludes matching child groups/instances.
      def paint_group(group, rgb, skip_name_re: nil)
        raise NotImplementedError
      end

      # Paint named direct children of +root+ with +rgb+. +names+ is an array
      # of group names (Outliner-style exact match).
      def paint_named_children(root, names, rgb)
        raise NotImplementedError
      end

      # Toggle visibility on named direct children of +root+.
      def hide_named_children(root, names, hidden: true)
        raise NotImplementedError
      end

      # Per-axis-aligned-face debug painting (six colours on the box faces of
      # every direct child not matching +skip_name_re+).
      def debug_paint_axis_faces(root, skip_name_re:)
        raise NotImplementedError
      end

      # Marks internal edges as soft/smooth to visually round segmented
      # geometry (native SketchUp softening; no plugin extension required).
      def soften_group_edges(group)
        raise NotImplementedError
      end

      # Rebuilds a sharp box in +group+ into a fully 3D rounded box using +radius+.
      # Intended as a post-process after a plain extrusion.
      def round_group_box_all_edges(group, size:, radius:)
        raise NotImplementedError
      end

      # ── Lifecycle ────────────────────────────────────────────────────────

      # Wraps an atomic "operation" (undoable on SketchUp; may be a no-op
      # elsewhere). Yields; if the block raises, the backend should abort.
      def commit(_label)
        yield
      end

      # Tells the backend to refresh / flush after a batch of operations.
      def invalidate_view; end
    end
  end
end
