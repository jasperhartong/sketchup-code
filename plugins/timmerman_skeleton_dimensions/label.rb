# encoding: utf-8
# label.rb — "Dimensions created on ..." label and notification.
# Loaded by core.rb; methods added to Timmerman::SkeletonDimensions.

module Timmerman
  module SkeletonDimensions
    def dimensions_label_version
      defined?(EXTENSION) && EXTENSION.respond_to?(:version) ? EXTENSION.version : VERSION
    end

    def show_dimensions_created_notification
      return unless defined?(EXTENSION) && EXTENSION
      msg = "Dimensions created successfully.\nThey may only show up after you leave the group you're currently nested in."
      notification = UI::Notification.new(EXTENSION, msg)
      notification.show
    end

    def add_dimensions_created_label(entities, corner_pt, view_h, view_v, sublayer)
      label_texts = entities.grep(Sketchup::Text).select { |t|
        t.layer == sublayer && t.text.to_s.start_with?(DIMENSIONS_LABEL_PREFIX)
      }
      entities.erase_entities(label_texts) unless label_texts.empty?

      date_time_str = Time.now.strftime('%Y-%m-%d %H:%M')
      version_str = dimensions_label_version
      text_str = "Dimensions: v#{version_str}\n#{date_time_str}"
      dir = Geom::Vector3d.new(view_h.x - view_v.x, view_h.y - view_v.y, view_h.z - view_v.z)
      len = Math.sqrt(dir.x**2 + dir.y**2 + dir.z**2)
      dir = Geom::Vector3d.new(dir.x / len, dir.y / len, dir.z / len) if len > 1.0e-9
      text_ent = entities.add_text(text_str, corner_pt, dir)
      text_ent.layer = sublayer
    end
  end
end
