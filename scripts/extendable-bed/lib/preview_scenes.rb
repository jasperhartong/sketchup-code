# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    remove_const :PreviewScenes if const_defined?(:PreviewScenes, false)

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

      CONSTRUCTION_STEP_RE = /\AEB_Step[1-8]_(Back|Front)\z/

      STANDARD_SCENES = [
        { key: :definitions,  title: 'Component definitions', camera: :iso,
          roots: :all_eb_roots },
        { key: :variants,     title: 'All variants',          camera: :iso,
          roots: EXTENSION_VARIANT_ROOTS },
        { key: :construction, title: 'Construction steps',    camera: :iso,
          roots: :construction_steps },
        { key: :cut_plan,     title: 'Cut plan',              camera: :top,
          roots: [Config::GROUP_CUT_PLAN_3D], optional: true },
        { key: :third_angle,     title: '3rd angle (retracted)', camera: :top,
          roots: :third_angle_group,     optional: true },
        { key: :third_angle_ext, title: '3rd angle (extended)',  camera: :top,
          roots: :third_angle_ext_group, optional: true }
      ].freeze

      module_function

      def scene_full_name(title) = "#{SCENE_PREFIX}#{title}"

      # Open empty scopes on +renderer+ (during +BedLayout#create+). Returns
      # { key => SceneScope } or nil when the renderer has no scene support.
      def open_scopes(renderer)
        return nil unless renderer.respond_to?(:scene)

        STANDARD_SCENES.to_h do |entry|
          [entry[:key], renderer.scene(scene_full_name(entry[:title]), camera: entry[:camera])]
        end
      end

      # Re-capture the standard scenes from geometry already in the model.
      def create_standard_set(model: Sketchup.active_model)
        missing = STANDARD_SCENES.reject { |e| e[:optional] }.find do |entry|
          roots_for_entry(model, entry).empty?
        end
        raise "#{missing[:title]} roots missing — run BedLayout#create first." if missing

        model.start_operation('EB scenes: standard set', true)
        _unhide_all_eb_roots(model)
        capture = Timmerman::SketchupUtils::SceneCapture.new(model)
        _register_on_capture(capture, model)
        created = capture.finalize!(purge_all: true)
        model.commit_operation
        _log_created(created)
        created
      end

      def finalize_on_renderer(model, renderer)
        return unless renderer.respond_to?(:finalize_scenes)

        model.start_operation('EB scenes', true)
        created = renderer.finalize_scenes(purge_all: true)
        model.commit_operation
        _log_created(created)
        created
      end

      def _register_on_capture(capture, model)
        STANDARD_SCENES.each do |entry|
          roots = roots_for_entry(model, entry)
          if roots.empty?
            warn "[EB scenes] #{entry[:title]} skipped — no roots." if entry[:optional]
            next
          end

          capture.scene(scene_full_name(entry[:title]), camera: entry[:camera]) do |s|
            s.track_all(*roots)
          end
        end
      end

      def roots_for_entry(model, entry)
        roots = entry[:roots]
        case roots
        when :construction_steps   then _construction_step_roots(model)
        when :all_eb_roots         then _all_eb_roots(model)
        when :third_angle_group    then _third_angle_root(model)
        when :third_angle_ext_group then _third_angle_ext_root(model)
        else _find_roots(model, roots)
        end
      end

      # Finds named roots by exact name match; handles both Group and
      # ComponentInstance (root pair groups are now ComponentDefinition instances
      # after BedLayout converts them with to_component!).
      def _find_roots(model, names)
        names.filter_map do |name|
          model.entities.find do |e|
            (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
              e.valid? && e.name == name
          end
        end
      end

      def _construction_step_roots(model)
        model.entities.select do |e|
          (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
            e.valid? && CONSTRUCTION_STEP_RE.match?(e.name)
        end
      end

      # All variant + step pair roots (excludes cut plan and 3rd angle container).
      # Used for the "Component definitions" overview scene.
      def _all_eb_roots(model)
        model.entities.select do |e|
          (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
            e.valid? &&
            (Config::GROUP_NAME_RE.match?(e.name) || Config::SINGLE_PAIR_ROOTS.include?(e.name))
        end
      end

      def _third_angle_root(model)
        root = model.entities.find do |e|
          e.is_a?(Sketchup::Group) && e.valid? && e.name == Config::GROUP_3RD_ANGLE
        end
        root ? [root] : []
      end

      def _third_angle_ext_root(model)
        root = model.entities.find do |e|
          e.is_a?(Sketchup::Group) && e.valid? && e.name == Config::GROUP_3RD_ANGLE_EXT
        end
        root ? [root] : []
      end

      def _unhide_all_eb_roots(model)
        all_3ap = _third_angle_root(model) + _third_angle_ext_root(model)
        (_all_eb_roots(model) + all_3ap).each do |e|
          e.hidden = false if e.respond_to?(:hidden=)
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
        created.each { |n| puts "  -- #{n}" }
      end
    end
  end
end
