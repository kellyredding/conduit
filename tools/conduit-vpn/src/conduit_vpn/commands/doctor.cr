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
        checks << check_last_teardown

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

      # A teardown older than this is history rather than a diagnosis. Naming
      # it every run would train a reader to skip the line, which costs the
      # day it actually matters.
      TEARDOWN_RECENT = 1.hour

      # Why the last session ended, when the client ended it for a reason.
      #
      # This is the only check that reports something the client did rather
      # than something about this machine's setup, and it earns the place: a
      # tunnel that dies seconds after connecting looks like a broken setup,
      # and this is the line that says it is not one.
      #
      # No profile name, per the note at the top of this file.
      private def check_last_teardown : Check
        reading = DaemonTeardown.latest

        unless reading
          return Check.new(Level::Pass, "last teardown", "none recorded")
        end

        age = Time.utc - reading.at
        if age > TEARDOWN_RECENT
          return Check.new(Level::Pass, "last teardown", "none in the last hour")
        end

        detail = "#{reading.cause.summary}, #{humanize(age)} ago"
        detail += " — a new sign-in is needed" if reading.needs_sign_in
        Check.new(Level::Warn, "last teardown", detail)
      end

      private def humanize(span : Time::Span) : String
        minutes = span.total_minutes.round.to_i
        return "less than a minute" if minutes < 1
        minutes == 1 ? "1 minute" : "#{minutes} minutes"
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
