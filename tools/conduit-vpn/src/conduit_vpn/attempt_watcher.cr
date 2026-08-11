module ConduitVPN
  # Polls a profile to a terminal outcome after a connect or disconnect.
  #
  # Two properties of the client make this less obvious than it looks.
  #
  # First, `connect` returns immediately with exit 0. That reports the attempt
  # *started*. Trusting it announces success on connections that never happen.
  #
  # Second, NotConnected is ambiguous: it is both "idle" and "the attempt you
  # just made failed". Nothing in the response distinguishes them. Conduit
  # separates them by watching for progress — once any transitional state has
  # been seen, a return to NotConnected is a failure. Before that it means the
  # client has not registered the attempt yet, which it needs a moment to do,
  # so a small number of consecutive readings are tolerated first.
  #
  # That tolerance is counted in polls rather than measured in seconds
  # deliberately. A slow machine changes how long a poll takes but not how
  # many readings it takes for the client to catch up, and a count makes the
  # behavior identical under a test clock and a real one.
  #
  # MIRROR (behavioral, not literal):
  #   ConduitApp/ConduitApp/Models/AttemptWatcher.swift
  class AttemptWatcher
    enum Outcome
      Connected
      Failed
      Disconnected
      TimedOut

      # A timeout is not a failure and must not share its exit code. With
      # sign-in happening in a browser, giving up watching says nothing about
      # whether the attempt will succeed — a caller that conflates the two
      # will retry something already in progress.
      def exit_code : Int32
        case self
        in .connected?, .disconnected? then 0
        in .failed?                    then 1
        in .timed_out?                 then 3
        end
      end

      def slug : String
        to_s.underscore.tr("_", "-")
      end
    end

    enum Event
      # The status changed. Fires once per distinct reading, not once per
      # poll, so narration does not repeat itself while nothing happens.
      Observed

      # Long enough in the sign-in state to be worth explaining. There is no
      # signal separating "the browser opened" from "someone is typing" from
      # "they walked away", so the only honest move is to say a browser is
      # waiting and keep watching.
      IdentityHint
    end

    # Injected so specs drive time instead of spending it.
    class Clock
      def monotonic : Time::Span
        Time.monotonic
      end

      def sleep(span : Time::Span) : Nil
        ::sleep(span) if span > Time::Span.zero
      end
    end

    alias Probe = Proc(Models::Status?)

    def initialize(@probe : Probe, @clock : Clock = Clock.new)
    end

    def self.for(client : Client, profile : String,
                 clock : Clock = Clock.new) : AttemptWatcher
      probe = -> do
        payload = client.capture(
          ["get-connection-status", "--profile-name", profile]
        )
        Models.connection_status(payload).status
      end
      new(probe.as(Probe), clock)
    end

    def watch_connect(
      timeout : Time::Span,
      hint_after : Time::Span,
      interval : Time::Span,
      grace_polls : Int32,
      &on_event : Event, Models::Status? ->
    ) : Outcome
      started = @clock.monotonic
      progressed = false
      idle_readings = 0
      hinted = false
      previous : Models::Status? = nil
      first = true

      loop do
        status = @probe.call
        elapsed = @clock.monotonic - started

        if first || status != previous
          on_event.call(Event::Observed, status)
          previous = status
          first = false
        end

        if status.nil?
          # A status this build does not recognize. Treated as motion rather
          # than as failure: a client that added a state did not thereby
          # break the connection.
          progressed = true
          idle_readings = 0
        elsif status.connected?
          return Outcome::Connected
        elsif status.not_connected?
          return Outcome::Failed if progressed
          idle_readings += 1
          return Outcome::Failed if idle_readings >= grace_polls
        else
          progressed = true
          idle_readings = 0

          if status.waiting_for_identity? && !hinted && elapsed >= hint_after
            on_event.call(Event::IdentityHint, status)
            hinted = true
          end
        end

        return Outcome::TimedOut if elapsed >= timeout
        @clock.sleep(interval)
      end
    end

    def watch_disconnect(
      timeout : Time::Span,
      interval : Time::Span,
      &on_event : Event, Models::Status? ->
    ) : Outcome
      started = @clock.monotonic
      previous : Models::Status? = nil
      first = true

      loop do
        status = @probe.call
        elapsed = @clock.monotonic - started

        if first || status != previous
          on_event.call(Event::Observed, status)
          previous = status
          first = false
        end

        return Outcome::Disconnected if status.try(&.not_connected?)
        return Outcome::TimedOut if elapsed >= timeout
        @clock.sleep(interval)
      end
    end
  end
end
