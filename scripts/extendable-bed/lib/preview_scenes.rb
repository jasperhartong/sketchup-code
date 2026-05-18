# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # SketchUp Scenes (tabs): camera jumps to each spatial band (no hide/show).
    # +STANDARD_SCENES+ is the single registry; +BedLayout#create+ opens scopes
    # during the build, +create_standard_set+ re-captures from existing roots.
    module PreviewScenes
      SCENE_PREFIX = 'EB | '

      EXTENSION_VARIANT_ROOTS = %w[
        EB_Ext1_Back EB_Ext1_Front
        EB_Ext_Back EB_Ext_Front
        EB_Ret_Back EB_Ret_Front
        EB_RetGnd_Back EB_RetGnd_Front
      ].freeze

      SCREWS_ONLY_ROOTS = %w[
        EB_RetScrews_Back EB_RetScrews_Front
      ].freeze

      CONSTRUCTION_STEP_RE = /\AEB_Step[1-8]_(Back|Front)\z/

      STANDARD_SCENES = [
        { key: :variants,     title: 'All variants',         view: :iso,
          roots: EXTENSION_VARIANT_ROOTS },
        { key: :screws_only,  title: 'Screws only',          view: :iso,
          roots: SCREWS_ONLY_ROOTS },
        { key: :construction, title: 'Construction steps', view: :iso,
          roots: :construction_steps },
        { key: :cut_plan,     title: 'Cut plan',             top: true,
          roots: [Config::GROUP_CUT_PLAN_3D], optional: true }
      ].freeze

      ORTHO_VIEWS = {
        side:   { label: 'Side',   view: :right },
        front:  { label: 'Front',  view: :front },
        back:   { label: 'Back',   view: :back },
        left:   { label: 'Left',   view: :left },
        top:    { label: 'Top',    view: :top },
        bottom: { label: 'Bottom', view: :bottom }
      }.freeze

      module_function

      def scene_full_name(title) = "#{SCENE_PREFIX}#{title}"

      # Open empty scopes on +renderer+ (during +BedLayout#create+). Returns
      # { key => SceneScope } or nil when the renderer has no scene support.
      def open_scopes(renderer)
        return nil unless renderer.respond_to?(:scene)

        STANDARD_SCENES.to_h do |entry|
          [entry[:key], renderer.scene(scene_full_name(entry[:title]), **_camera_opts(entry))]
        end
      end

      # Re-capture the standard scenes from geometry already in the model.
      def create_standard_set(model: Sketchup.active_model)
        missing = STANDARD_SCENES.reject { |e| e[:optional] }.find do |entry|
          roots_for_entry(model, entry).empty?
        end
        if missing
          raise "#{missing[:title]} roots missing — run BedLayout#create first."
        end

        model.start_operation('EB scenes: standard set', true)
        _unhide_all_eb_roots(model)
        capture = Timmerman::SketchupUtils::SceneCapture.new(model)
        _register_on_capture(capture, model)
        created = capture.finalize!(purge_all: true)
        model.commit_operation
        _log_created(created)
        created
      end

      def create_for_variant(variant, model: Sketchup.active_model, views: %i[side front top])
        spec = {
          ext1:       %w[EB_Ext1_Back EB_Ext1_Front],
          extended:   %w[EB_Ext_Back EB_Ext_Front],
          retracted:  [Config::GROUP_RET_BACK, Config::GROUP_RET_FRONT],
          ret_gnd:    %w[EB_RetGnd_Back EB_RetGnd_Front],
          ret_screws: SCREWS_ONLY_ROOTS
        }.fetch(variant)
        short = { ext1: 'Ext1', extended: 'Ext', retracted: 'Ret',
                  ret_gnd: 'RetGnd', ret_screws: 'RetScr' }.fetch(variant)
        roots = _find_roots(model, spec)

        model.start_operation("EB scenes: #{short}", true)
        _unhide_all_eb_roots(model)
        _remove_scenes_with_prefix(model, "#{SCENE_PREFIX}#{short} |")

        capture = Timmerman::SketchupUtils::SceneCapture.new(model)
        views.each do |key|
          v = ORTHO_VIEWS.fetch(key)
          capture.scene("#{SCENE_PREFIX}#{short} | #{v[:label]}", view: v[:view], parallel: true) do |s|
            s.track_all(*roots)
          end
        end
        created = capture.finalize!
        model.commit_operation
        created
      end

      def create_all_extension_variants(model: Sketchup.active_model)
        %i[ext1 extended retracted ret_gnd ret_screws].flat_map do |v|
          create_for_variant(v, model: model)
        end
      end

      def finalize_on_renderer(model, renderer)
        return unless renderer.respond_to?(:finalize_scenes)

        model.start_operation('EB scenes', true)
        created = renderer.finalize_scenes(purge_all: true)
        model.commit_operation
        _log_created(created)
        created
      end

      def _camera_opts(entry)
        opts = {}
        opts[:view] = entry[:view] if entry[:view]
        opts[:top] = true if entry[:top]
        opts[:parallel] = entry[:parallel] if entry.key?(:parallel)
        opts
      end

      def _register_on_capture(capture, model)
        STANDARD_SCENES.each do |entry|
          roots = roots_for_entry(model, entry)
          if roots.empty?
            warn "[EB scenes] #{entry[:title]} skipped — no roots." if entry[:optional]
            next
          end

          capture.scene(scene_full_name(entry[:title]), **_camera_opts(entry)) do |s|
            s.track_all(*roots)
          end
        end
      end

      def roots_for_entry(model, entry)
        roots = entry[:roots]
        case roots
        when :construction_steps then _construction_step_roots(model)
        else _find_roots(model, roots)
        end
      end

      def _find_roots(model, names)
        names.filter_map do |name|
          model.entities.grep(Sketchup::Group).find { |g| g.valid? && g.name == name }
        end
      end

      def _construction_step_roots(model)
        model.entities.grep(Sketchup::Group).select do |g|
          g.valid? && CONSTRUCTION_STEP_RE.match?(g.name)
        end
      end

      def _all_eb_root_groups(model)
        model.entities.grep(Sketchup::Group).select do |g|
          g.valid? && (
            Config::GROUP_NAME_RE.match?(g.name) ||
            Config::SINGLE_PAIR_ROOTS.include?(g.name) ||
            g.name == Config::GROUP_CUT_PLAN_3D
          )
        end
      end

      def _unhide_all_eb_roots(model)
        _all_eb_root_groups(model).each do |g|
          g.hidden = false if g.respond_to?(:hidden=)
        end
      end

      def _remove_scenes_with_prefix(model, prefix)
        loop do
          pages = model.pages.to_a
          victim = pages.find { |p| p.name.start_with?(prefix) }
          break unless victim

          model.pages.erase(victim)
        end
      end

      def _log_created(created)
        puts "[EB scenes] #{created.size} scene(s)"
        created.each { |n| puts "  — #{n}" }
      end
    end
  end
end
