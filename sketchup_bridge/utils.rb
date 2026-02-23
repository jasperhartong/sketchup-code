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
end
