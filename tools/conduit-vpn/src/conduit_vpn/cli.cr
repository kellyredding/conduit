module ConduitVPN
  module CLI
    extend self

    # `2` matches the client's own convention for a usage error, so a caller
    # that already special-cases it keeps working when a command is forwarded
    # rather than handled here. `3` is Conduit's own: see AttemptWatcher for
    # why a timeout must not share an exit code with a failure.
    OK      = 0
    FAILURE = 1
    USAGE   = 2

    # Forwarded to the client untouched. Enumerated rather than treating
    # anything unrecognized as forwardable: a mistyped command reports its own
    # name back instead of an opaque usage dump from a binary the caller did
    # not think they were invoking. The cost is that a command added by a
    # future client release needs a line here before it can be reached.
    VENDOR_COMMANDS = {
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

    # Client commands Conduit adds behavior to. Still accept every flag the
    # client does, and behave identically when Conduit's own flags are absent.
    EXTENDED_COMMANDS = {
      "connect"    => "Connect a profile        [--wait] [--yes] [--timeout N]",
      "disconnect" => "Disconnect a profile     [--wait] [--timeout N]",
    }

    NATIVE_COMMANDS = {
      "status"  => "Show every profile and its connection state  [--json]",
      "config"  => "Read and write settings   [get|set|unset|describe|example]",
      "doctor"  => "Check that this machine is set up correctly",
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
      when "status"
        return Commands::Status.run(argv[1..])
      when "config"
        return Commands::Settings.run(argv[1..])
      when "doctor"
        return Commands::Doctor.run(argv[1..])
      when "connect"
        return Commands::Connect.run(argv)
      when "disconnect"
        return Commands::Disconnect.run(argv)
      end

      name = command.not_nil!

      unless VENDOR_COMMANDS.has_key?(name)
        STDERR.puts "conduit-vpn: unknown command: #{name}"
        STDERR.puts "Run `conduit-vpn --help` for the available commands."
        return USAGE
      end

      forward(argv)
    end

    def help_requested?(argv : Array(String)) : Bool
      argv.any? { |argument| argument == "--help" || argument == "-h" }
    end

    # Help for a command that is Conduit's own, with no client half to append.
    def print_help(text : String) : Int32
      STDOUT.puts text
      OK
    end

    # Help for a command Conduit extends, showing both halves.
    #
    # `--help` on these was forwarded to the client, which documents its own
    # flags and has never heard of Conduit's. So the one place a caller looks to
    # find out whether `--wait` exists answered no — and anything reasoning from
    # that, an agent especially, would correctly conclude it had to poll by hand,
    # which is the thing `--wait` was added to stop. Documentation that
    # contradicts the tool is worse than none, because it is believed.
    #
    # Conduit's additions print first, then the client's own list, so one command
    # answers the whole question.
    def extended_help(command : String, additions : String) : Int32
      STDOUT.puts additions
      STDOUT.puts
      STDOUT.puts "The client's own options, forwarded untouched:"
      STDOUT.puts
      # Flushed because the client inherits this stdout and writes to it
      # directly; buffered output would otherwise arrive after its help.
      STDOUT.flush

      guard { Client.from_config.exec([command, "--help"]) }
    end

    # One place where every expected failure becomes a readable line and a
    # non-zero exit. Without it each command grows the same rescue clauses and
    # they drift, which shows up as one command reporting a missing client
    # helpfully and another dumping a backtrace.
    def guard(&) : Int32
      yield
    rescue error : ConduitVPN::Error
      STDERR.puts "conduit-vpn: #{error.message}"
      FAILURE
    rescue error : JSON::Error
      STDERR.puts "conduit-vpn: could not read the client's response " \
                  "(#{error.message})"
      FAILURE
    end

    private def forward(argv : Array(String)) : Int32
      guard { Client.from_config.exec(argv) }
    end

    private def usage : String
      String.build do |io|
        io << "conduit-vpn — command-line client for AWS Client VPN\n\n"
        io << "Usage: conduit-vpn <command> [options]\n\n"
        io << "Conduit commands:\n"
        NATIVE_COMMANDS.each { |name, blurb| io << line(name, blurb) }
        io << "\nClient commands, with additions:\n"
        EXTENDED_COMMANDS.each { |name, blurb| io << line(name, blurb) }
        io << "\nClient commands, forwarded unchanged:\n"
        VENDOR_COMMANDS.each { |name, blurb| io << line(name, blurb) }
        io << "\nRun `conduit-vpn <command> --help` for a command's options.\n"
      end
    end

    private def line(name : String, blurb : String) : String
      "  #{name.ljust(22)}#{blurb}\n"
    end
  end
end
