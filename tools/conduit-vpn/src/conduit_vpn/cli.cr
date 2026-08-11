module ConduitVPN
  module CLI
    extend self

    # Exit codes. `2` matches the client's own convention for a usage error,
    # so a caller that already special-cases it keeps working when a command
    # is forwarded rather than handled here.
    OK      = 0
    FAILURE = 1
    USAGE   = 2

    # Forwarded to the client untouched. Enumerated rather than treating
    # anything unrecognized as forwardable: a mistyped command reports its
    # own name back instead of an opaque usage dump from a binary the caller
    # did not think they were invoking. The cost is that a command added by
    # a future client release needs a line here before it can be reached.
    VENDOR_COMMANDS = {
      "connect"               => "Connect a profile",
      "disconnect"            => "Disconnect a profile",
      "get-connection-status" => "Show the connection status for one profile",
      "list-connections"      => "List active connections",
      "list-profiles"         => "List known profiles",
      "get-config"            => "Print a profile's configuration",
      "import-profile"        => "Import a profile",
      "delete-profile"        => "Delete a profile",
      "list-preferences"      => "List client preferences",
      "put-preference"        => "Set a client preference",
      "send-diagnostic-logs"  => "Upload diagnostic logs to the vendor",
    }

    NATIVE_COMMANDS = {
      "version" => "Print the conduit-vpn version",
    }

    def run(argv : Array(String)) : NoReturn
      exit(dispatch(argv))
    end

    def dispatch(argv : Array(String)) : Int32
      command = argv.first?

      case command
      when nil
        STDERR.puts usage
        return USAGE
      when "--help", "-h", "help"
        STDOUT.puts usage
        return OK
      when "--version", "-V", "version"
        STDOUT.puts ConduitVPN::VERSION
        return OK
      end

      # `command` is non-nil here, but the compiler cannot see that through
      # the case above.
      name = command.not_nil!

      unless VENDOR_COMMANDS.has_key?(name)
        STDERR.puts "conduit-vpn: unknown command: #{name}"
        STDERR.puts "Run `conduit-vpn --help` for the available commands."
        return USAGE
      end

      forward(argv)
    end

    private def forward(argv : Array(String)) : Int32
      Client.from_config.exec(argv)
    rescue error : Client::NotInstalled | Client::HomeNotCanonical
      STDERR.puts "conduit-vpn: #{error.message}"
      FAILURE
    end

    private def usage : String
      String.build do |io|
        io << "conduit-vpn — command-line client for AWS Client VPN\n\n"
        io << "Usage: conduit-vpn <command> [options]\n\n"
        io << "Conduit commands:\n"
        NATIVE_COMMANDS.each { |name, blurb| io << command_line(name, blurb) }
        io << "\nAWS VPN Client commands, forwarded unchanged:\n"
        VENDOR_COMMANDS.each { |name, blurb| io << command_line(name, blurb) }
        io << "\nRun `conduit-vpn <command> --help` for a command's options.\n"
      end
    end

    private def command_line(name : String, blurb : String) : String
      "  #{name.ljust(22)}#{blurb}\n"
    end
  end
end
