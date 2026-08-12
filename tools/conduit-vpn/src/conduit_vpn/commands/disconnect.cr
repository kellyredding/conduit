module ConduitVPN
  module Commands
    module Disconnect
      extend self

      HELP = <<-TEXT
        conduit-vpn disconnect — disconnect a profile

        Added by Conduit:
          --wait          Watch until the profile actually reaches a resting
                          state, rather than returning as soon as the client
                          accepts the request. The client prints nothing at all
                          on success, so without this the exit code is the only
                          signal that anything happened.
          --timeout N     Seconds to keep watching with --wait. Defaults to the
                          connect-timeout setting.

        Disconnecting also clears a stalled attempt, which is the only thing that
        does — a profile held by one refuses every replacement for about ten
        minutes while no tunnel exists.
        TEXT

      def run(argv : Array(String)) : Int32
        return CLI.extended_help("disconnect", HELP) if CLI.help_requested?(argv)

        flags = Flags.split(argv)
        profile = Flags.value_of(flags.forward, "--profile-name")

        CLI.guard do
          if timeout = flags.timeout
            ::ConduitVPN::Config.override("connect-timeout", timeout)
          end

          client = Client.from_config

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

        # The client prints nothing at all on a successful disconnect, so
        # empty output here is the expected case and not a sign of trouble.
        # Only a non-zero exit carries information, and that raises.
        client.capture(forward)

        watcher = AttemptWatcher.for(client, profile)
        outcome = watcher.watch_disconnect(
          timeout: ::ConduitVPN::Config.seconds("connect-timeout"),
          interval: ::ConduitVPN::Config.seconds("poll-interval-active"),
        ) do |event, status|
          case event
          in .observed?
            STDERR.puts "  #{status.try(&.label) || "unrecognized state"}"
          in .identity_hint?
            # Never emitted while disconnecting; no sign-in is involved.
          end
        end

        elapsed = Time.monotonic - started

        case outcome
        in .disconnected?
          STDERR.puts "#{profile} disconnected"
        in .timed_out?
          STDERR.puts "stopped watching #{profile} after " \
                      "#{elapsed.total_seconds.round.to_i}s — it has not " \
                      "reported a clean teardown yet"
        in .connected?, .failed?
          STDERR.puts "#{profile} is still connected"
        end

        STDOUT.puts JSON.build(indent: "  ") { |json|
          json.object do
            json.field "profile-name", profile
            json.field "outcome", outcome.slug
            json.field "elapsed-seconds", elapsed.total_seconds.round(1)
          end
        }

        outcome.exit_code
      end
    end
  end
end
