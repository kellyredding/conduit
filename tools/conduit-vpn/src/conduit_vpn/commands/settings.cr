module ConduitVPN
  module Commands
    # Reached as `conduit-vpn config`. Named Settings here so that plain
    # `Config` keeps resolving to the resolver in every sibling command —
    # a module named Config under Commands would shadow it for all of them.
    module Settings
      extend self

      HELP = <<-TEXT
        conduit-vpn config — read and write settings

        Actions:
          (none)                  Every setting, its value, and which layer it
                                  came from. The source column is the point:
                                  "why is it doing that" is answered by which
                                  layer won, not by the value alone.
          get <key>               One value
          set <key> <value>       Record a value in the config file
          unset <key>             Remove it, reverting to the layer beneath
          describe                Every key, what it does, and its variable
          example                 A fully documented config file, on stdout

        Settings resolve flag > environment > config file > compiled default, so
        a `set` can leave the effective value unchanged when a variable outranks
        it. That case is reported rather than left to be discovered.
        TEXT

      def run(argv : Array(String)) : Int32
        # Answered here rather than falling through to the unknown-action
        # branch, which exited 2 on a request for help — the same trap the
        # extended client commands had. Somebody asking how a command works
        # should not have to read an error to find out.
        return CLI.print_help(HELP) if CLI.help_requested?(argv)

        CLI.guard do
          case argv.first?
          when nil        then list
          when "get"      then get(argv[1]?)
          when "set"      then set(argv[1]?, argv[2]?)
          when "unset"    then unset(argv[1]?)
          when "describe" then describe
          when "example"  then example
          else
            STDERR.puts "conduit-vpn: unknown config action: #{argv.first}"
            STDERR.puts "Actions: get, set, unset, describe, example"
            CLI::USAGE
          end
        end
      end

      # The source column is the reason this command exists. "Why is it doing
      # that" is answered by which layer won, not by the value alone.
      private def list : Int32
        resolved = ::ConduitVPN::Config.effective
        name_width = resolved.map(&.key.name.size).max
        value_width = resolved.map(&.value.size).max

        resolved.each do |entry|
          STDOUT.puts [
            entry.key.name.ljust(name_width),
            entry.value.ljust(value_width),
            "(#{entry.source.label})",
          ].join("  ")
        end

        CLI::OK
      end

      private def get(name : String?) : Int32
        return missing_argument("a setting name") unless name
        STDOUT.puts ::ConduitVPN::Config.get(name)
        CLI::OK
      end

      private def set(name : String?, value : String?) : Int32
        return missing_argument("a setting name") unless name
        return missing_argument("a value") unless value

        ::ConduitVPN::Config.set(name, value)
        resolved = ::ConduitVPN::Config.resolve(name)

        STDOUT.puts "#{name} = #{resolved.value}"

        # Writing the file does not necessarily change the effective value:
        # an environment variable outranks it. Saying so prevents a long hunt
        # for why an edit appeared to do nothing.
        unless resolved.source.file?
          STDERR.puts "note: #{name} is currently taken from the " \
                      "#{resolved.source.label} layer, which outranks the " \
                      "config file"
        end

        CLI::OK
      end

      private def unset(name : String?) : Int32
        return missing_argument("a setting name") unless name
        ::ConduitVPN::Config.unset(name)
        resolved = ::ConduitVPN::Config.resolve(name)
        STDOUT.puts "#{name} = #{resolved.value} (#{resolved.source.label})"
        CLI::OK
      end

      private def describe : Int32
        ::ConduitVPN::Config.keys.each do |key|
          STDOUT.puts key.name
          STDOUT.puts "  #{key.description}"
          STDOUT.puts "  environment: #{key.env}"
          STDOUT.puts
        end
        CLI::OK
      end

      private def example : Int32
        STDOUT.print ::ConduitVPN::Config.example_json
        CLI::OK
      end

      private def missing_argument(what : String) : Int32
        STDERR.puts "conduit-vpn: expected #{what}"
        CLI::USAGE
      end
    end
  end
end
