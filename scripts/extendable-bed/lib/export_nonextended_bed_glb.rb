# frozen_string_literal: true

module Timmerman
  module ExtendableBed
    # Native SketchUp GLB export for one logical bed: the retracted (non-extended)
    # preview roots from {Config::NONEXTENDED_GLB_EXPORT_ROOTS}.
    #
    # The GLB exporter does not document `selectionset_only`; we hide every other
    # root +Drawingelement+, export, then restore visibility.
    module GlbExport
      module_function

      # @param path [String] destination path; extension must be `.glb` (SketchUp 2024+).
      # @param model [Sketchup::Model]
      # @return [Boolean] same as {Sketchup::Model#export}
      def export_nonextended_pair(path, model = Sketchup.active_model)
        stash = []
        roots = Config::NONEXTENDED_GLB_EXPORT_ROOTS
        expanded = File.expand_path(path)
        unless File.extname(expanded).casecmp?('.glb')
          raise ArgumentError, "GlbExport: path must end with .glb (got #{path.inspect})"
        end

        model.entities.each do |e|
          next unless e.respond_to?(:hidden?) && e.respond_to?(:hidden=)

          stash << [e, e.hidden?]
          keep = e.is_a?(Sketchup::Group) && roots.include?(e.name)
          e.hidden = !keep
        end

        model.export(expanded)
      ensure
        stash.each do |ent, was_hidden|
          ent.hidden = was_hidden if ent.valid?
        end
      end
    end
  end
end
