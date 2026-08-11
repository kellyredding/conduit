module ConduitVPN
  module Commands
    module Connect
      extend self

      def run(argv : Array(String)) : Int32
        flags = Flags.split(argv)
        profile = Flags.value_of(flags.forward, "--profile-name")

        CLI.guard do
          # Refused before the client is touched at all, so a declined
          # connection leaves no attempt recorded anywhere.
          Sensitivity.guard!(profile, confirmed: flags.yes) if profile

          if timeout = flags.timeout
            ::ConduitVPN::Config.override("connect-timeout", timeout)
          end

          client = Client.from_config

          # Without --wait the behavior is the client's own: start the attempt
          # and report what it said. The guard above is the only difference.
          next client.exec(flags.forward) unless flags.wait

          unless profile
            STDERR.puts "conduit-vpn: --wait requires --profile-name"
            next CLI::USAGE
          end

          watch(client, profile, flags.forward)
        end
      end

      private def watch(client : Client, profile : String,
                        forward : Array(String)) : Int32
        started = Time.monotonic

        # Starting the attempt is itself a client call that can fail — a
        # missing profile, or a connection limit already reached.
        client.capture(forward)

        watcher = AttemptWatcher.for(client, profile)
        outcome = watcher.watch_connect(
          timeout: ::ConduitVPN::Config.seconds("connect-timeout"),
          hint_after: ::ConduitVPN::Config.seconds("identity-hint-after"),
          interval: ::ConduitVPN::Config.seconds("poll-interval-active"),
          grace_polls: ::ConduitVPN::Config.int("connect-grace-polls"),
        ) { |event, status| narrate(event, status) }

        report(profile, outcome, Time.monotonic - started)
        outcome.exit_code
      end

      # Progress goes to stderr so that stdout carries only the final result
      # and stays pipeable into a JSON reader.
      private def narrate(event : AttemptWatcher::Event,
                          status : Models::Status?) : Nil
        case event
        in .observed?
          STDERR.puts "  #{status.try(&.label) || "unrecognized state"}"
        in .identity_hint?
          STDERR.puts "  a browser window is waiting for sign-in — " \
                      "finish there and this will continue"
        end
      end

      private def report(profile : String, outcome : AttemptWatcher::Outcome,
                         elapsed : Time::Span) : Nil
        case outcome
        in .connected?
          STDERR.puts "connected to #{profile}"
        in .failed?
          STDERR.puts "#{profile} did not connect"
        in .timed_out?
          # Deliberately not phrased as a failure. Sign-in happens in a
          # browser and may be waiting on a person, so giving up watching
          # says nothing about whether the attempt will succeed.
          STDERR.puts "stopped watching #{profile} after " \
                      "#{elapsed.total_seconds.round.to_i}s — the attempt may " \
                      "still be waiting for sign-in. Check with: " \
                      "conduit-vpn status"
        in .disconnected?
          STDERR.puts "#{profile} is not connected"
        end

        STDOUT.puts result_json(profile, outcome, elapsed)
      end

      private def result_json(profile : String,
                              outcome : AttemptWatcher::Outcome,
                              elapsed : Time::Span) : String
        JSON.build(indent: "  ") do |json|
          json.object do
            json.field "profile-name", profile
            json.field "outcome", outcome.slug
            json.field "elapsed-seconds", elapsed.total_seconds.round(1)
          end
        end
      end
    end
  end
end
