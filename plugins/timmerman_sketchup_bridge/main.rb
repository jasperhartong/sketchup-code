# main.rb — plugin entry point
# Loads the listener logic and the UI. Edit core.rb to change polling behaviour.

load File.join(File.dirname(__FILE__), 'core.rb')
require File.join(File.dirname(__FILE__), 'ui')
