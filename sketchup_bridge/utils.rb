# sketchup_bridge/utils.rb — helpers for command.rb scripts
#
# Load from command.rb:
#   load File.expand_path('utils.rb', __dir__)

module SketchupBridgeUtils
  extend self

  remove_const(:RESULTS_DIR) if const_defined?(:RESULTS_DIR, false)
  RESULTS_DIR = File.expand_path('results', File.dirname(__FILE__)).freeze

  # Take a screenshot of the current SketchUp view.
  # Returns the full path to the saved image.
  #
  #   take_screenshot                          # timestamped PNG
  #   take_screenshot(name: "after_fix")       # results/after_fix.png
  #   take_screenshot(width: 1920, height: 1080)
  #
  def take_screenshot(name: nil, width: nil, height: nil, antialias: true)
    view = Sketchup.active_model.active_view
    view.refresh

    filename = name ? "#{name}.png" : "screenshot_#{Time.now.strftime('%Y-%m-%d_%H-%M-%S')}.png"
    path = File.join(RESULTS_DIR, filename)
    FileUtils.mkdir_p(RESULTS_DIR) unless Dir.exist?(RESULTS_DIR)

    opts = { :filename => path, :antialias => antialias }
    opts[:width]  = width  if width
    opts[:height] = height if height
    view.write_image(opts)

    puts "[screenshot] #{path}"
    path
  end

  # Erase every full-circle edge ring at the model root (scope the propose /
  # delete commands use). Returns the number of rings removed. Silent when
  # there are none — callers can wrap with their own messaging.
  def delete_root_proposal_circles(model = Sketchup.active_model)
    edges = model.entities.grep(Sketchup::Edge).select do |e|
      curve = e.curve
      curve.is_a?(Sketchup::ArcCurve) &&
        ((curve.end_angle - curve.start_angle).abs - 2 * Math::PI).abs < 1e-3
    end
    return 0 if edges.empty?

    rings = edges.group_by { |e| e.curve.entityID }
    model.start_operation('Delete proposal circles', true)
    begin
      rings.each_value do |ring|
        alive = ring.select(&:valid?)
        model.entities.erase_entities(alive) unless alive.empty?
      end
      model.commit_operation
    rescue StandardError
      model.abort_operation
      raise
    end
    rings.size
  end
end
