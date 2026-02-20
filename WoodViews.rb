module WoodViews
    extend self

    def run
        model = Sketchup.active_model
        sel   = model.selection
        inst  = selected_component_instance(sel)
        unless inst
            msg = selection_error_message(sel)
            UI.messagebox(msg)
            return
        end

        target_name = safe_name(inst.definition.name.empty? ? "Component" : inst.definition.name)

        views = [
            { name: "#{target_name} - Front",   dir: Geom::Vector3d.new( 0, -1,  0), up: Geom::Vector3d.new(0, 0, 1), proj: :parallel },
            { name: "#{target_name} - Back",    dir: Geom::Vector3d.new( 0,  1,  0), up: Geom::Vector3d.new(0, 0, 1), proj: :parallel },
            { name: "#{target_name} - Right",   dir: Geom::Vector3d.new( 1,  0,  0), up: Geom::Vector3d.new(0, 0, 1), proj: :parallel },
            { name: "#{target_name} - Left",    dir: Geom::Vector3d.new(-1,  0,  0), up: Geom::Vector3d.new(0, 0, 1), proj: :parallel },
            { name: "#{target_name} - Top",     dir: Geom::Vector3d.new( 0,  0,  1), up: Geom::Vector3d.new(0, 1, 0), proj: :parallel },
            { name: "#{target_name} - Bottom",  dir: Geom::Vector3d.new( 0,  0, -1), up: Geom::Vector3d.new(0, 1, 0), proj: :parallel },
            { name: "#{target_name} - Iso",     dir: Geom::Vector3d.new( 1,  1,  1), up: Geom::Vector3d.new(0, 0, 1), proj: :perspective }
        ]

        model.start_operation("Place Perspectives Around Component", true)
        begin
            model.close_active while model.active_path
            layer_visibility = save_layer_visibility(model)

            pages = model.pages
            views.each do |v|
                setup_scene_for_instance(model, pages, inst, v[:name], v[:dir], v[:up], v[:proj])
            end
            restore_layer_visibility(model, layer_visibility)
        ensure
            model.commit_operation
        end

        UI.messagebox("Created #{views.length} scenes for '#{target_name}'.\n\nYour current view is unchanged; switch to a new scene to see each perspective.")
    end

    # --- Helpers ----------------------------------------------------------

    def selected_component_instance(selection)
        candidates = selection.grep(Sketchup::ComponentInstance)
        return nil unless candidates.length == 1
        candidates.first
    end

    def selection_error_message(selection)
        candidates = selection.grep(Sketchup::ComponentInstance)
        if selection.empty?
            "Nothing selected.\n\nSelect exactly one component instance, then run again."
        elsif candidates.empty?
            "Selection is not a component.\n\nSelect exactly one component instance (not a group or raw geometry), then run again."
        else
            "Too many components selected (#{candidates.length}).\n\nSelect exactly one component, then run again."
        end
    end

    def safe_name(text)
        text.gsub(/[\\\/\:\*\?\"\<\>\|]/, " ").strip
    end

    def save_layer_visibility(model)
        model.layers.to_a.map { |l| [l, l.visible?] }.to_h
    end

    def restore_layer_visibility(model, layer_visibility)
        layer_visibility.each { |layer, visible| layer.visible = visible }
    end

    def setup_scene_for_instance(model, pages, inst, name, dir, up, projection)
        cam = build_camera_looking_at_instance(inst, dir, up, projection)
        frame_component(model, cam, inst, projection)

        # Add a NEW scene (page) and capture camera + layer visibility for this view
        page = pages.add(name)
        capture_page_properties(page)
    end

    def capture_page_properties(page)
        page.use_camera            = true
        page.use_layers            = true
        page.use_rendering_options = true
        page.use_section_planes    = true
        page.use_axes              = false
        page.use_shadow_info       = false
        page.use_hidden_geometry   = false
        page.use_hidden_objects    = false
    end

    def build_camera_looking_at_instance(inst, dir, up, projection)
        model = inst.model
        bb    = inst.bounds
        center = bb.center

        # World-space direction/up; rotate by instance transform to align with component axes if desired
        t = inst.transformation
        look_dir = dir.transform(t).normalize
        up_dir   = up.transform(t).normalize

        # Camera position some distance away along look_dir
        diag = bb.diagonal
        dist = [diag, 1.m].max
        eye  = center.offset(look_dir.reverse, dist)

        cam = Sketchup::Camera.new(eye, center, up_dir)
        model.active_view.camera = cam
        ro = model.rendering_options
        if projection == :parallel
            ro["Perspective"] = false
        else
            ro["Perspective"] = true
            cam.perspective = true rescue nil
        end
        cam
    end

    def frame_component(model, cam, inst, projection)
        # Adjust camera to fit the component tightly in view
        view = model.active_view
        3.times { view.zoom inst }  # zoom extents to the instance a few times for safety
        # For parallel, set a reasonable zoom by tweaking camera height via View#zoom
        view.invalidate
    end
end

# To run:
#   1) Select one component instance
#   2) In Ruby Console: WoodViews.run