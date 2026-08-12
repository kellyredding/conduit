module ConduitVPN
  module Commands
    # Answers "is this machine set up correctly" as a list of independent
    # checks rather than by failing on the first problem, because the answer
    # is usually more than one thing and a person fixing them wants the whole
    # list.
    #
    # Reports counts, never profile names. Diagnostic output is the most likely
    # thing to be pasted somewhere public.
    module Doctor
      extend self

      enum Level
        Pass
        Warn
        Fail

        def marker : String
          case self
          in .pass? then "ok  "
          in .warn? then "warn"
          in .fail? then "FAIL"
          end
        end
      end

      record Check, level : Level, name : String, detail : String

      def run(argv : Array(String)) : Int32
        if argv.includes?("--explain")
          STDOUT.puts Network.synthesis_explanation
          return CLI::OK
        end

        checks = [] of Check

        binary = ::ConduitVPN::Config.client_path
        home = ::ConduitVPN::Config.client_home
        client = Client.new(binary, home)

        # Only these two gate the rest: without a usable binary and a usable
        # home there is nothing to ask. Everything else reports independently,
        # and a warning from any of them must not silence the checks below —
        # which is exactly what gating on "every check passed" did.
        preconditions = [check_binary(client, binary), check_home(client, home)]
        checks.concat(preconditions)
        checks << check_address_synthesis

        if preconditions.all?(&.level.pass?)
          responds = check_responds(client)
          checks << responds
          checks << check_profiles(client) if responds.level.pass?
        end

        width = checks.map(&.name.size).max
        checks.each do |result|
          STDOUT.puts "#{result.level.marker}  " \
                      "#{result.name.ljust(width)}  #{result.detail}"
        end

        checks.any?(&.level.fail?) ? CLI::FAILURE : CLI::OK
      end

      # Reported whether or not it is a problem, so this command's output has
      # the same shape everywhere. A check that appears only when it fails is
      # a check nobody knows exists until the day it does.
      private def check_address_synthesis : Check
        if Network.synthesizing_addresses?
          Check.new(
            Level::Warn,
            "addressing",
            "#{Network.summary} — connections will fail here; " \
            "run `conduit-vpn doctor --explain` for why",
          )
        else
          Check.new(Level::Pass, "addressing", Network.summary)
        end
      end

      private def check_binary(client : Client, binary : Path) : Check
        client.ensure_installed!
        Check.new(Level::Pass, "client binary", binary.to_s)
      rescue error : Client::NotInstalled
        Check.new(Level::Fail, "client binary", "not found at #{binary}")
      end

      private def check_home(client : Client, home : Path) : Check
        client.ensure_client_home!
        Check.new(Level::Pass, "client home", home.to_s)
      rescue error : Client::HomeNotCanonical
        Check.new(
          Level::Fail,
          "client home",
          "#{home} is reached through a symlink; the client would abort",
        )
      rescue error : ::File::Error
        Check.new(Level::Fail, "client home", "cannot create #{home}")
      end

      private def check_responds(client : Client) : Check
        client.capture(["list-profiles"])
        Check.new(Level::Pass, "client responds", "answered a profile listing")
      rescue error : Client::CommandFailed
        Check.new(
          Level::Fail,
          "client responds",
          error.message || "the client returned an error",
        )
      end

      private def check_profiles(client : Client) : Check
        profiles = Models.profiles(client.capture(["list-profiles"]))

        if profiles.empty?
          # Not a failure. Conduit does not provision profiles, so an empty
          # list is a legitimate state that simply leaves nothing to connect.
          Check.new(
            Level::Warn,
            "profiles",
            "none installed — nothing to connect to",
          )
        else
          Check.new(Level::Pass, "profiles", "#{profiles.size} installed")
        end
      rescue error : JSON::Error
        Check.new(
          Level::Fail,
          "profiles",
          "the client's response could not be read",
        )
      end
    end
  end
end
