require "../spec_helper"

# Sleeping advances the clock instead of spending time, so an example can span
# a simulated two minutes without taking any.
class FakeClock < ConduitVPN::AttemptWatcher::Clock
  property elapsed : Time::Span = Time::Span.zero
  getter slept = [] of Time::Span

  def monotonic : Time::Span
    @elapsed
  end

  def sleep(span : Time::Span) : Nil
    @slept << span
    @elapsed += span
  end
end

private alias Status = ConduitVPN::Models::Status
private alias Watcher = ConduitVPN::AttemptWatcher

# Yields each status in turn, then repeats the last one indefinitely — the
# client keeps answering after a sequence runs out, and so must the double.
private def probe_over(sequence : Array(Status?)) : Watcher::Probe
  index = 0
  -> do
    value = index < sequence.size ? sequence[index] : sequence.last
    index += 1
    # Widened explicitly: a sequence containing no nils would otherwise infer
    # a narrower proc than the watcher accepts.
    value.as(Status?)
  end
end

private def watch(sequence : Array(Status?),
                  timeout = 60.seconds,
                  hint_after = 15.seconds,
                  interval = 2.seconds,
                  grace_polls = 3)
  clock = FakeClock.new
  watcher = Watcher.new(probe_over(sequence), clock)
  events = [] of {Watcher::Event, Status?}

  outcome = watcher.watch_connect(
    timeout: timeout,
    hint_after: hint_after,
    interval: interval,
    grace_polls: grace_polls,
  ) { |event, status| events << {event, status} }

  {outcome, events, clock}
end

describe ConduitVPN::AttemptWatcher do
  describe "#watch_connect" do
    it "succeeds once the client reports a live tunnel" do
      outcome, _, _ = watch([
        Status::WaitingForIdentity,
        Status::Connecting,
        Status::Connected,
      ])

      outcome.should eq(Watcher::Outcome::Connected)
    end

    # The ambiguity at the center of this class: NotConnected means both
    # "idle" and "your attempt failed", and only observed progress separates
    # them.
    it "treats a return to not-connected after progress as a failure" do
      outcome, _, _ = watch([
        Status::WaitingForIdentity,
        Status::Connecting,
        Status::NotConnected,
      ])

      outcome.should eq(Watcher::Outcome::Failed)
    end

    it "tolerates not-connected readings before the attempt registers" do
      # Connected only on the third reading. A watcher that called the first
      # not-connected a failure would report the opposite of the truth.
      outcome, _, _ = watch(
        [Status::NotConnected, Status::NotConnected, Status::Connected],
        grace_polls: 3,
      )

      outcome.should eq(Watcher::Outcome::Connected)
    end

    it "gives up on an attempt that never registers at all" do
      outcome, _, clock = watch(
        [Status::NotConnected] of Status?,
        grace_polls: 3,
        interval: 2.seconds,
      )

      outcome.should eq(Watcher::Outcome::Failed)
      # Three readings means two waits between them, and no more.
      clock.slept.size.should eq(2)
    end

    it "distinguishes giving up watching from failing" do
      outcome, _, _ = watch(
        [Status::WaitingForIdentity] of Status?,
        timeout: 10.seconds,
        interval: 2.seconds,
      )

      outcome.should eq(Watcher::Outcome::TimedOut)
      outcome.exit_code.should eq(3)
      Watcher::Outcome::Failed.exit_code.should eq(1)
    end

    it "explains the browser once it has waited long enough to be worth it" do
      _, events, _ = watch(
        [Status::WaitingForIdentity] of Status?,
        timeout: 20.seconds,
        hint_after: 5.seconds,
        interval: 2.seconds,
      )

      hints = events.select { |event, _| event.identity_hint? }
      hints.size.should eq(1)
    end

    it "does not explain the browser when sign-in completes promptly" do
      _, events, _ = watch(
        [Status::WaitingForIdentity, Status::Connected],
        hint_after: 15.seconds,
        interval: 2.seconds,
      )

      events.any? { |event, _| event.identity_hint? }.should be_false
    end

    it "reports each distinct state once rather than once per poll" do
      _, events, _ = watch([
        Status::WaitingForIdentity,
        Status::WaitingForIdentity,
        Status::WaitingForIdentity,
        Status::Connecting,
        Status::Connected,
      ])

      observed = events.select { |event, _| event.observed? }.map { |_, s| s }
      observed.should eq([
        Status::WaitingForIdentity,
        Status::Connecting,
        Status::Connected,
      ])
    end

    # A client release that adds a state should not turn every connection
    # into a reported failure.
    it "keeps waiting through a state it does not recognize" do
      outcome, _, _ = watch([nil, nil, Status::Connected] of Status?)

      outcome.should eq(Watcher::Outcome::Connected)
    end

    it "does not call an unrecognized state a failure by way of the grace count" do
      outcome, _, _ = watch(
        [nil, nil, nil, nil, Status::Connected] of Status?,
        grace_polls: 2,
      )

      outcome.should eq(Watcher::Outcome::Connected)
    end
  end

  describe "#watch_disconnect" do
    it "succeeds when the tunnel is gone" do
      clock = FakeClock.new
      watcher = Watcher.new(
        probe_over([Status::Disconnecting, Status::NotConnected] of Status?),
        clock,
      )

      outcome = watcher.watch_disconnect(
        timeout: 30.seconds,
        interval: 2.seconds,
      ) { }

      outcome.should eq(Watcher::Outcome::Disconnected)
      outcome.exit_code.should eq(0)
    end

    it "gives up on a teardown that never completes" do
      clock = FakeClock.new
      watcher = Watcher.new(
        probe_over([Status::Disconnecting] of Status?),
        clock,
      )

      outcome = watcher.watch_disconnect(
        timeout: 6.seconds,
        interval: 2.seconds,
      ) { }

      outcome.should eq(Watcher::Outcome::TimedOut)
    end
  end
end
