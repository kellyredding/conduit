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

          # One tunnel at a time, whoever asked.
          release_others(client, profile) if profile

          # Without --wait the behavior is the client's own: start the attempt
          # and report what it said. The guard above and the release below are
          # the only differences.
          next client.exec(flags.forward) unless flags.wait

          unless profile
            STDERR.puts "conduit-vpn: --wait requires --profile-name"
            next CLI::USAGE
          end

          watch(client, profile, flags.forward)
        end
      end

      # Leaves the named profile as the only one the client is holding.
      #
      # The client permits several concurrent tunnels and this deployment is
      # not routed for them: asking for a second while one is live simply
      # fails, with a message that describes a limit rather than the choice
      # behind it. Nobody wants two, and being told to go and disconnect the
      # first one by hand is a step with no decision in it.
      #
      # Deliberately not a prompt. Whoever is asking can already see which
      # profile is live and is asking for a different one, so a confirmation
      # would only ask them to repeat themselves.
      #
      # The target is left alone. If it is the one already connected, the
      # client's own "already connected" answer is still the right one, and
      # tearing down a working tunnel to rebuild it identically would be a
      # surprising thing for a repeated command to do.
      private def release_others(client : Client, profile : String) : Nil
        # A listing that cannot be read must not cost the caller their connect.
        # Exclusivity is a convenience on top of the thing actually being asked
        # for, and refusing to connect at all because the tidying step failed
        # would trade a working command for a housekeeping rule.
        listed = begin
          Models.connections(client.capture(["list-connections"]))
        rescue error
          STDERR.puts "  could not check for other connections: #{error.message}"
          return
        end

        listed.each do |connection|
          next if connection.name == profile

          STDERR.puts "  disconnecting #{connection.name}"
          begin
            client.capture(["disconnect", "--profile-name", connection.name])
          rescue error : Client::CommandFailed
            # Reported rather than raised. The connect that follows is the
            # thing being asked for, and it will fail loudly enough on its own
            # if this release was the reason it could not proceed.
            STDERR.puts "  could not disconnect #{connection.name}: #{error.message}"
          end
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
          # Only asked after a failure. On this network the client tears down
          # its own working tunnel and says so nowhere the caller can see, so
          # a failure with no explanation is the expected outcome rather than
          # a rare one.
          if Network.synthesizing_addresses?
            STDERR.puts
            STDERR.puts Network.synthesis_explanation
          end
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
