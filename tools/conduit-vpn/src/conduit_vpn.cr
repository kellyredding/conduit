# Explicit and first: the glob below loads alphabetically, which would reach
# the exception classes that descend from Error before Error itself exists.
# A superclass has to be defined at the point its subclass is compiled.
require "./conduit_vpn/error"
require "./conduit_vpn/**"

module ConduitVPN
  VERSION = {{ read_file("#{__DIR__}/../VERSION.txt").strip }}
end

# Specs require this file to reach the library without also running the
# program. Integration specs invoke the built binary as a subprocess
# instead, which is the only way to observe exit codes and stream handling
# the way a caller does.
unless ENV.has_key?("CONDUIT_SKIP_CLI")
  ConduitVPN::CLI.run(ARGV)
end
