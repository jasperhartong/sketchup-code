# frozen_string_literal: true
#
# Delete the rough circle markers the user drew at the model root to indicate
# screw positions. The default rebuild command.rb already does this before
# every rebuild; this standalone command exists for the rare case where you
# want to wipe markers without a rebuild. Only circles at the MODEL ROOT are
# removed — nested circles inside EB groups are left alone (the rebuild
# rewrites those roots anyway).

$VERBOSE = nil

load File.expand_path('../utils.rb', __dir__)

cleared = SketchupBridgeUtils.delete_root_proposal_circles
puts cleared.positive? ? "[delete-proposal-circles] removed #{cleared} circle(s)." : '[delete-proposal-circles] no root-level full circles found — nothing to do.'
'OK'
