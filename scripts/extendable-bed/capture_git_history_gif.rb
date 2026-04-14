#!/usr/bin/env ruby
# frozen_string_literal: true

# Thin launcher for the shared util (extendable-bed preset).
# See: scripts/sketchup_utils/capture_git_history_gif.rb

util = File.expand_path('../sketchup_utils/capture_git_history_gif.rb', __dir__)
exec Gem.ruby, util, '--preset', 'extendable-bed', *ARGV
