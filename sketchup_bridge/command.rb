project_root = File.expand_path(File.join(File.dirname(__FILE__), '..'))
load File.join(project_root, 'Dimensions.rb')
Dimensions.clear
Dimensions.run
"OK"
