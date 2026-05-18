# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # SketchUp Scenes (tabs): camera jumps to each spatial band (no hide/show).
    # Layout bands are separated in +Config+ (+preview_band_gap+):
    #   — extension previews @ +extension_preview_row_y+
    #   — construction steps @ +construction_steps_row_y+
    #   — cut plan @ +cut_plan_row_y+
    #
    #   Timmerman::ExtendableBed::PreviewScenes.create_standard_set
    module PreviewScenes
      SCENE_PREFIX = 'EB | '

      EXTENSION_VARIANT_ROOTS = %w[
        EB_Ext1_Back EB_Ext1_Front
        EB_Ext_Back EB_Ext_Front
        EB_Ret_Back EB_Ret_Front
        EB_RetGnd_Back EB_RetGnd_Front
        EB_RetScrews_Back EB_RetScrews_Front
      ].freeze

      CONSTRUCTION_STEP_RE = /\AEB_Step[1-8]_(Back|Front)\z/

      ORTHO_VIEWS = {
        side:   { label: 'Side',   action: 'viewRight:' },
        front:  { label: 'Front',  action: 'viewFront:' },
        back:   { label: 'Back',   action: 'viewBack:' },
        left:   { label: 'Left',   action: 'viewLeft:' },
        top:    { label: 'Top',    action: 'viewTop:' },
        bottom: { label: 'Bottom', action: 'viewBottom:' }
      }.freeze

      module_function

      def create_standard_set(model: Sketchup.active_model)
        model.start_operation('EB scenes: standard set', true)
        removed = _purge_all_pages(model)
        _unhide_all_eb_roots(model)

        variant_roots = _find_roots(model, EXTENSION_VARIANT_ROOTS)
        raise 'Extension preview roots missing — run BedLayout#create first.' if variant_roots.empty?

        step_roots = _construction_step_roots(model)
        raise 'Construction step roots missing — run BedLayout#create first.' if step_roots.empty?

        cut_plan = _find_roots(model, [Config::GROUP_CUT_PLAN_3D]).first

        created = []
        created << _capture_scene(
          model, "#{SCENE_PREFIX}All variants", variant_roots,
          view_action: 'viewIso:', parallel: nil
        )
        created << _capture_scene(
          model, "#{SCENE_PREFIX}Construction steps", step_roots,
          view_action: 'viewIso:', parallel: nil
        )
        if cut_plan
          created << _capture_cut_plan_top_scene(model, "#{SCENE_PREFIX}Cut plan", cut_plan)
        else
          warn '[EB scenes] Cut plan group not found (show_cut_plan_3d off?) — skipped Cut plan scene.'
        end

        _drop_stray_pages(model, keep_names: created.to_set)
        model.commit_operation
        puts "[EB scenes] #{created.size} scene(s)#{" (removed #{removed} old)" if removed.positive?}"
        created.each { |n| puts "  — #{n}" }
        created
      end

      def create_for_variant(variant, model: Sketchup.active_model, views: %i[side front top])
        spec = {
          ext1:       %w[EB_Ext1_Back EB_Ext1_Front],
          extended:   %w[EB_Ext_Back EB_Ext_Front],
          retracted:  [Config::GROUP_RET_BACK, Config::GROUP_RET_FRONT],
          ret_gnd:    %w[EB_RetGnd_Back EB_RetGnd_Front],
          ret_screws: %w[EB_RetScrews_Back EB_RetScrews_Front]
        }.fetch(variant)
        short = { ext1: 'Ext1', extended: 'Ext', retracted: 'Ret',
                  ret_gnd: 'RetGnd', ret_screws: 'RetScr' }.fetch(variant)
        roots = _find_roots(model, spec)
        model.start_operation("EB scenes: #{short}", true)
        _unhide_all_eb_roots(model)
        _remove_scenes_with_prefix(model, "#{SCENE_PREFIX}#{short} |")
        created = views.map do |key|
          v = ORTHO_VIEWS.fetch(key)
          _capture_scene(model, "#{SCENE_PREFIX}#{short} | #{v[:label]}", roots,
                         view_action: v[:action], parallel: true)
        end
        model.commit_operation
        created
      end

      def create_all_extension_variants(model: Sketchup.active_model)
        %i[ext1 extended retracted ret_gnd ret_screws].flat_map do |v|
          create_for_variant(v, model: model)
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

      def _drop_stray_pages(model, keep_names:)
        model.pages.to_a.each do |page|
          next if keep_names.include?(page.name)

          model.pages.erase(page)
        end
      end

      def _purge_all_pages(model)
        removed = 0
        loop do
          pages = model.pages.to_a
          break if pages.empty?

          model.pages.erase(pages.last)
          removed += 1
        rescue StandardError
          break
        end
        removed
      end

      def _remove_scenes_with_prefix(model, prefix)
        removed = 0
        model.pages.to_a.each do |page|
          next unless page.name.start_with?(prefix)

          model.pages.erase(page)
          removed += 1
        end
        removed
      end

      # Camera only — visibility stays as in the model (spatial bands, not per-scene hide).
      def _scene_capture_flags
        PAGE_USE_CAMERA
      end

      # Plan view: parallel projection, eye on +Z, up = +Y (head→foot), framed on cut-plan root.
      def _capture_cut_plan_top_scene(model, scene_name, cut_plan_root)
        view = model.active_view
        cam  = view.camera
        bb   = _world_bounds([cut_plan_root])
        c    = bb.center

        cam.perspective = false
        cam.set(
          Geom::Point3d.new(c.x, c.y, bb.max.z + bb.diagonal * 2.0),
          Geom::Point3d.new(c.x, c.y, c.z),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom([cut_plan_root])
        cam.perspective = false

        page = model.pages.add(scene_name)
        page.name = scene_name
        page.update(_scene_capture_flags)
        scene_name
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

      def _capture_scene(model, scene_name, zoom_targets, view_action:, parallel: true)
        view = model.active_view

        Sketchup.send_action(view_action)
        view.camera.perspective = false if parallel == true
        view.zoom(zoom_targets)

        page = model.pages.add(scene_name)
        page.name = scene_name
        page.update(_scene_capture_flags)
        scene_name
      end
    end
  end
end
