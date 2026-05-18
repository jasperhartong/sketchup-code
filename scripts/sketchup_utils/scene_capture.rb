# frozen_string_literal: true

module Timmerman
  module SketchupUtils
    remove_const :SceneCapture if const_defined?(:SceneCapture, false)

    # Deferred SketchUp scene (Page) tabs: register zoom targets while building
    # geometry, then capture cameras in one pass.
    #
    # Usage:
    #   capture = SceneCapture.new(model)
    #   capture.scene('My iso view', camera: :iso) { |s| s.track(root) }
    #   capture.scene('Cut plan',    camera: :top) { |s| s.track(root) }
    #   capture.finalize!
    #
    # camera: values
    #   :iso    — NW parallel isometric  (eye at -X, +Y, +Z relative to center)
    #   :top    — parallel plan view     (eye above, up = +Y)
    #   :front  — parallel front         (uses Sketchup.send_action)
    #   :back   — parallel back
    #   :left   — parallel left
    #   :right  — parallel right (side)
    #   :bottom — parallel bottom
    class SceneCapture
      # PAGE_USE_CAMERA (= 1) is a global constant defined by the SketchUp runtime.

      SEND_ACTION_CAMERAS = {
        front:  'viewFront:',
        back:   'viewBack:',
        left:   'viewLeft:',
        right:  'viewRight:',
        bottom: 'viewBottom:'
      }.freeze

      SceneScope = Struct.new(:spec, keyword_init: true) do
        def track(entity)
          return unless entity&.valid?

          spec[:roots] << entity
        end

        def track_all(*entities)
          entities.flatten.compact.each { track(_1) }
        end

        def track_pair(back, front)
          track_all(back, front)
        end
      end

      def initialize(model)
        @model = model
        @specs = []
      end

      # Register a scene. Returns a SceneScope; call +track+ on each root
      # group that should be framed. Optionally pass a block.
      #
      # @param camera [:iso, :top, :front, :back, :left, :right, :bottom]
      def scene(name, camera: :iso)
        spec = { name: name, camera: camera, roots: [] }
        @specs << spec
        scope = SceneScope.new(spec: spec)
        yield scope if block_given?
        scope
      end

      # @param purge_all [Boolean] erase every existing page before adding scenes
      # @return [Array<String>] names of scenes created
      def finalize!(prefix: nil, purge_all: false)
        purge_all ? _purge_all_pages : _purge_pages(prefix) if purge_all || (prefix && !prefix.empty?)
        _unhide_tracked_roots

        @specs.filter_map do |spec|
          roots = spec[:roots].select(&:valid?)
          next if roots.empty?

          _capture_scene(@model, spec, roots)
          spec[:name]
        end
      end

      private

      def _purge_all_pages
        loop do
          pages = @model.pages.to_a
          break if pages.empty?

          @model.pages.erase(pages.last)
        rescue StandardError
          break
        end
      end

      def _purge_pages(prefix)
        loop do
          pages = @model.pages.to_a
          victim = pages.reverse.find { |p| p.name.start_with?(prefix) }
          break unless victim

          @model.pages.erase(victim)
        end
      end

      def _unhide_tracked_roots
        @specs.each do |spec|
          spec[:roots].each do |g|
            g.hidden = false if g.valid? && g.respond_to?(:hidden=)
          end
        end
      end

      def _capture_scene(model, spec, roots)
        case spec[:camera]
        when :iso    then _set_iso_camera(model.active_view, roots)
        when :top    then _set_top_camera(model.active_view, roots)
        else              _set_action_camera(model.active_view, spec[:camera], roots)
        end
        page = model.pages.add(spec[:name])
        page.name = spec[:name]
        page.update(PAGE_USE_CAMERA)
      end

      # ---- Camera implementations ------------------------------------------

      # Sketchup.send_action is unreliable from the bridge for :iso and :top,
      # so those two are set via explicit camera math. Others use send_action.

      # NW parallel isometric: eye at (-X, +Y, +Z) relative to scene center.
      def _set_iso_camera(view, roots)
        bb = _world_bounds(roots)
        c  = bb.center
        d  = [bb.diagonal, 1.0].max
        cam = view.camera
        cam.perspective = false
        cam.set(Geom::Point3d.new(c.x - d, c.y + d, c.z + d), c, Geom::Vector3d.new(0, 0, 1))
        view.zoom(roots)
      end

      # Plan view: eye above center, up = +Y (head-to-foot readable).
      def _set_top_camera(view, roots)
        bb = _world_bounds(roots)
        c  = bb.center
        d  = [bb.diagonal, 1.0].max
        cam = view.camera
        cam.perspective = false
        cam.set(
          Geom::Point3d.new(c.x, c.y, bb.max.z + d * 2.0),
          Geom::Point3d.new(c.x, c.y, c.z),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom(roots)
      end

      # Front / back / side: use SketchUp's built-in action, then force parallel.
      def _set_action_camera(view, camera_sym, roots)
        action = SEND_ACTION_CAMERAS.fetch(camera_sym) do
          raise ArgumentError, "Unknown camera: #{camera_sym.inspect}"
        end
        Sketchup.send_action(action)
        view.camera.perspective = false
        view.zoom(roots)
      end

      def _world_bounds(entities)
        bb = Geom::BoundingBox.new
        entities.each do |e|
          next unless e.valid?

          b = e.bounds
          t = e.transformation
          8.times { |i| bb.add(b.corner(i).transform(t)) }
        end
        bb
      end
    end
  end
end
