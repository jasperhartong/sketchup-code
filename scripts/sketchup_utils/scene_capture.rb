# frozen_string_literal: true

module Timmerman
  module SketchupUtils
    # Deferred SketchUp scene (Page) tabs: register zoom targets while building
    # geometry, then capture cameras in one pass.
    #
    #   capture.scene('My view', view: :iso) { |s| s.track(root) }
    #   capture.finalize!
    class SceneCapture
      VIEW_ACTIONS = {
        iso:    'viewIso:',
        front:  'viewFront:',
        back:   'viewBack:',
        left:   'viewLeft:',
        right:  'viewRight:',
        top:    'viewTop:',
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

      # @return [SceneScope]
      def create_scene(name, view: :iso, parallel: nil, top: false)
        view_action = VIEW_ACTIONS.fetch(view) { view }
        spec = { name: name, view: view_action, parallel: parallel, top: top, roots: [] }
        @specs << spec
        SceneScope.new(spec: spec)
      end

      def scene(name, view: :iso, parallel: nil, top: false)
        scope = create_scene(name, view: view, parallel: parallel, top: top)
        yield scope if block_given?
        scope
      end

      # @param prefix [String] remove pages whose names start with this (ignored when +purge_all+)
      # @param purge_all [Boolean] erase every page before adding registered scenes
      # @return [Array<String>] scene names created
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
        if spec[:top]
          _capture_top_camera(model.active_view, roots)
        else
          _capture_view_camera(model.active_view, roots,
                               view_action: spec[:view], parallel: spec[:parallel])
        end
        _add_page(model, spec[:name])
      end

      def _capture_view_camera(view, roots, view_action:, parallel:)
        Sketchup.send_action(view_action)
        view.camera.perspective = false if parallel
        view.zoom(roots)
      end

      def _capture_top_camera(view, roots)
        cam = view.camera
        bb  = _world_bounds(roots)
        c   = bb.center

        cam.perspective = false
        cam.set(
          Geom::Point3d.new(c.x, c.y, bb.max.z + bb.diagonal * 2.0),
          Geom::Point3d.new(c.x, c.y, c.z),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom(roots)
        cam.perspective = false
      end

      def _add_page(model, scene_name)
        page = model.pages.add(scene_name)
        page.name = scene_name
        page.update(PAGE_USE_CAMERA)
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
