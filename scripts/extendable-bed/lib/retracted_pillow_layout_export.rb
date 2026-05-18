# frozen_string_literal: true

require 'fileutils'

module Timmerman
  module ExtendableBed
    # Builds a LayOut sheet set for the retracted preview pair (pillows on top):
    # side elevation, front elevation, and top plan — each with a small set of
    # orthographic dimensions (frame lengths/heights + couch stack).
    #
    # Requires SketchUp Pro (LayOut Ruby API). Writes `.layout` and optionally `.pdf`.
    #
    #   Timmerman::ExtendableBed::RetractedPillowLayoutExport.export(
    #     model: Sketchup.active_model,
    #     config: Timmerman::ExtendableBed::Config.new
    #   )
    module RetractedPillowLayoutExport
      module_function

      OUTPUT_DIR = File.expand_path('../output', __dir__).freeze
      DEFAULT_LAYOUT_BASENAME = 'EB_retracted_pillows.layout'.freeze
      DEFAULT_PDF_BASENAME    = 'EB_retracted_pillows.pdf'.freeze

      # Paper inches — viewport inset on a letter page.
      VIEWPORT_BOUNDS = Geom::Bounds2d.new(0.85, 1.35, 10.15, 6.85).freeze
      TITLE_BOUNDS    = Geom::Bounds2d.new(0.85, 0.45, 10.15, 1.05).freeze
      DIM_OFFSET_IN   = 0.42

      PAGE_SPECS = [
        {
          name: 'Side elevation',
          view: :right,
          dims: %i[retracted_length slat_top couch_stack]
        },
        {
          name: 'Front elevation',
          view: :front,
          dims: %i[width couch_stack]
        },
        {
          name: 'Top plan',
          view: :top,
          dims: %i[width plan_length]
        }
      ].freeze

      VIEW_BY_KEY = {
        right: -> { Layout::SketchUpModel::RIGHT_VIEW },
        front: -> { Layout::SketchUpModel::FRONT_VIEW },
        top:   -> { Layout::SketchUpModel::TOP_VIEW }
      }.freeze

      # @param model [Sketchup::Model]
      # @param config [Config]
      # @param layout_path [String, nil]
      # @param pdf_path [String, nil] pass +false+ to skip PDF export
      # @return [Hash] paths and page names
      def export(model: Sketchup.active_model, config: Config.new,
                 layout_path: nil, pdf_path: nil)
        _ensure_layout_api!

        layout_path ||= File.join(OUTPUT_DIR, DEFAULT_LAYOUT_BASENAME)
        pdf_path = File.join(OUTPUT_DIR, DEFAULT_PDF_BASENAME) if pdf_path.nil?

        FileUtils.mkdir_p(File.dirname(layout_path))

        _find_retracted_roots!(model)
        skp_path = _ensure_saved_skp!(model, layout_path)
        anchors  = _dimension_anchors(config)

        visibility_stash = _isolate_retracted_pair!(model)
        model.save unless model.path == skp_path

        doc = Layout::Document.new
        doc.units = Layout::Document::DECIMAL_MILLIMETERS
        doc.precision = 0.1
        layer = doc.layers.first

        PAGE_SPECS.each_with_index do |spec, idx|
          page = idx.zero? ? doc.pages.first : doc.pages.add(spec[:name])
          page.name = spec[:name]
          _build_page(doc, layer, page, skp_path, spec, anchors)
        end

        doc.save(layout_path)
        exported_pdf = pdf_path && _export_pdf(doc, pdf_path)

        {
          layout_path: layout_path,
          skp_path: skp_path,
          pdf_path: exported_pdf,
          pages: PAGE_SPECS.map { |s| s[:name] }
        }
      ensure
        _restore_visibility!(visibility_stash) if visibility_stash
      end

      def _ensure_layout_api!
        return if defined?(Layout::Document)

        raise 'LayOut Ruby API is not available (SketchUp Pro with LayOut required).'
      end

      def _find_retracted_roots!(model)
        missing = Config::NONEXTENDED_GLB_EXPORT_ROOTS.reject do |name|
          model.entities.grep(Sketchup::Group).any? { |g| g.valid? && g.name == name }
        end
        return if missing.empty?

        raise "Retracted preview roots not found: #{missing.join(', ')}. Run BedLayout#create first."
      end

      def _ensure_saved_skp!(model, layout_path)
        path = model.path
        return File.expand_path(path) if path && !path.empty?

        skp = File.join(File.dirname(layout_path),
                        File.basename(layout_path, '.layout') + '.skp')
        model.save(skp)
        File.expand_path(skp)
      end

      def _isolate_retracted_pair!(model)
        stash = []
        keep = Config::NONEXTENDED_GLB_EXPORT_ROOTS
        model.entities.each do |e|
          next unless e.respond_to?(:hidden?) && e.respond_to?(:hidden=)

          stash << [e, e.hidden?]
          show = e.is_a?(Sketchup::Group) && keep.include?(e.name)
          e.hidden = !show
        end
        stash
      end

      def _restore_visibility!(stash)
        stash.each do |ent, was_hidden|
          ent.hidden = was_hidden if ent.valid?
        end
      end

      # Model-space anchor points (inches) for retracted pair at column 0 (back at origin).
      def _dimension_anchors(c)
        len = c.usable_length_retracted
        ox  = c.outer_width * 1.12
        y0  = -c.plank_thickness * 0.35
        z_mid = c.z_slat_bottom * 0.45
        z_slat = c.z_slat_top
        z_stack = z_slat + c.pillow_thickness + c.pillow_small_length
        z_plan = z_slat + c.pillow_thickness * 0.5

        {
          retracted_length: [
            Geom::Point3d.new(ox, 0, z_mid),
            Geom::Point3d.new(ox, len, z_mid)
          ],
          width: [
            Geom::Point3d.new(0, y0, z_mid),
            Geom::Point3d.new(c.outer_width, y0, z_mid)
          ],
          slat_top: [
            Geom::Point3d.new(ox, 0, 0),
            Geom::Point3d.new(ox, 0, z_slat)
          ],
          couch_stack: [
            Geom::Point3d.new(ox * 0.55, y0, z_slat),
            Geom::Point3d.new(ox * 0.55, y0, z_stack)
          ],
          plan_length: [
            Geom::Point3d.new(c.outer_width * 0.5, 0, z_plan),
            Geom::Point3d.new(c.outer_width * 0.5, len, z_plan)
          ]
        }
      end

      def _build_page(doc, layer, page, skp_path, spec, anchors)
        title = Layout::FormattedText.new(
          "#{Config::PREVIEW_NAME_RET} — #{spec[:name]}",
          TITLE_BOUNDS
        )
        doc.add_entity(title, layer, page)

        su_model = Layout::SketchUpModel.new(skp_path, VIEWPORT_BOUNDS)
        su_model.view = VIEW_BY_KEY.fetch(spec[:view]).call
        su_model.perspective = false
        su_model.display_background = false
        su_model.render_mode = Layout::SketchUpModel::HYBRID_RENDER
        su_model.render
        doc.add_entity(su_model, layer, page)

        spec[:dims].each do |key|
          pair = anchors.fetch(key)
          _add_model_dimension(doc, layer, page, su_model, pair[0], pair[1], spec[:view])
        end
      end

      def _add_model_dimension(doc, layer, page, su_model, p1, p2, view_key)
        pa = su_model.model_to_paper_point(p1)
        pb = su_model.model_to_paper_point(p2)
        alignment = _alignment_for_segment(view_key, p1, p2)
        dim = Layout::LinearDimension.new(pa, pb, DIM_OFFSET_IN, alignment)
        dim.auto_scale = true
        cp1 = Layout::ConnectionPoint.new(su_model, p1)
        cp2 = Layout::ConnectionPoint.new(su_model, p2)
        dim.connect(cp1, cp2)
        doc.add_entity(dim, layer, page)
        dim
      rescue StandardError => e
        warn "[EB layout] dimension skipped (#{view_key} #{p1} → #{p2}): #{e.message}"
        nil
      end

      def _alignment_for_segment(view_key, p1, p2)
        dx = (p2.x - p1.x).abs
        dy = (p2.y - p1.y).abs
        dz = (p2.z - p1.z).abs

        case view_key
        when :right, :left
          return Layout::LinearDimension::DIMENSION_LINE_HORIZONTAL if dy >= dx && dy >= dz
          return Layout::LinearDimension::DIMENSION_LINE_VERTICAL if dz >= dx && dz >= dy
        when :front, :back
          return Layout::LinearDimension::DIMENSION_LINE_HORIZONTAL if dx >= dy && dx >= dz
          return Layout::LinearDimension::DIMENSION_LINE_VERTICAL if dz >= dx && dz >= dy
        when :top, :bottom
          return Layout::LinearDimension::DIMENSION_LINE_HORIZONTAL if dx >= dy && dx >= dz
          return Layout::LinearDimension::DIMENSION_LINE_VERTICAL if dy >= dx && dy >= dz
        end

        Layout::LinearDimension::DIMENSION_LINE_ALIGNED
      end

      def _export_pdf(doc, pdf_path)
        FileUtils.mkdir_p(File.dirname(pdf_path))
        doc.export(pdf_path)
        pdf_path if File.file?(pdf_path)
      rescue StandardError => e
        warn "[EB layout] PDF export failed: #{e.message}"
        nil
      end
    end
  end
end
