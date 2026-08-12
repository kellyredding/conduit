require "../spec_helper"

# Every example here drives the fixture client. Nothing in this file can reach
# a real VPN, which is the only acceptable way to test a command whose job is
# to change network routing.
private def no_waiting : Hash(String, String?)
  {"CONDUIT_POLL_ACTIVE" => "0"} of String => String?
end

describe "connect" do
  it "reports what the client reported when --wait is absent" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-connections", "[]")
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      result = SpecHelper.run(sandbox, ["connect", "--profile-name", "Alpha"])

      result.exit_code.should eq(0)
      result.stdout.should contain("WaitingForIdentity")
      # The listing that enforces one-at-a-time, then the attempt. Still no
      # polling: without --wait what gets reported is the client's own answer.
      sandbox.calls.size.should eq(2)
    end
  end
end

# One tunnel at a time. The client permits several and this deployment is not
# routed for them, so asking for a second while one is live simply fails —
# and being told to go and disconnect the first by hand is a step with no
# decision in it.
describe "connect exclusivity" do
  it "releases another live profile before starting the attempt" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "list-connections",
        %([{"profile-name": "Bravo", "initiated-by": "someone",
            "connection-status": "Connected",
            "last-updated-at": "2026-01-01T00:00:00-05:00"}])
      )
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      result = SpecHelper.run(sandbox, ["connect", "--profile-name", "Alpha"])

      result.exit_code.should eq(0)
      result.stderr.should contain("disconnecting Bravo")

      released = sandbox.calls.index(&.includes?("disconnect"))
      attempted = sandbox.calls.index(&.includes?("connect --profile-name Alpha"))
      released.should_not be_nil
      attempted.should_not be_nil
      # Ordering is the whole point: releasing after the attempt would tear
      # down the tunnel just asked for.
      (released.not_nil! < attempted.not_nil!).should be_true
    end
  end

  # Tearing down a working tunnel to rebuild it identically would be a
  # surprising thing for a repeated command to do, so the client's own
  # "already connected" answer stays the answer.
  it "leaves the target alone when it is the one already connected" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "list-connections",
        %([{"profile-name": "Alpha", "initiated-by": "someone",
            "connection-status": "Connected",
            "last-updated-at": "2026-01-01T00:00:00-05:00"}])
      )
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      SpecHelper.run(sandbox, ["connect", "--profile-name", "Alpha"])

      sandbox.calls.any?(&.includes?("disconnect")).should be_false
    end
  end

  it "also releases a profile that is merely holding an attempt" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "list-connections",
        %([{"profile-name": "Bravo", "initiated-by": "someone",
            "connection-status": "WaitingForIdentity",
            "last-updated-at": "2026-01-01T00:00:00-05:00"}])
      )
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      SpecHelper.run(sandbox, ["connect", "--profile-name", "Alpha"])

      sandbox.calls.any? { |call|
        call.includes?("disconnect") && call.includes?("Bravo")
      }.should be_true
    end
  end

  # Exclusivity is a convenience on top of the thing actually being asked for.
  # Refusing to connect at all because the tidying step failed would trade a
  # working command for a housekeeping rule.
  it "still connects when the listing cannot be read" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha"],
        {"FAKE_VPN_EXIT_LIST_CONNECTIONS" => "1"} of String => String?
      )

      result.exit_code.should eq(0)
      result.stdout.should contain("WaitingForIdentity")
    end
  end
end

describe "connect --wait" do
  it "reports success only once the state has settled" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "WaitingForIdentity"}),
        %({"connection-status": "Connecting"}),
        %({"connection-status": "Connected"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait"],
        no_waiting,
      )

      result.exit_code.should eq(0)
      result.stdout.should contain(%("outcome": "connected"))
      result.stderr.should contain("waiting for sign-in")
      result.stderr.should contain("connecting")
      result.stderr.should contain("connected to Alpha")
    end
  end

  # The failure the client's exit code cannot express: it reported 0 and
  # "started" for an attempt that then collapsed.
  it "fails when the attempt collapses back to not connected" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "WaitingForIdentity"}),
        %({"connection-status": "Connecting"}),
        %({"connection-status": "NotConnected"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait"],
        no_waiting,
      )

      result.exit_code.should eq(1)
      result.stdout.should contain(%("outcome": "failed"))
      result.stderr.should contain("did not connect")
    end
  end

  it "waits out the readings before the client registers the attempt" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "NotConnected"}),
        %({"connection-status": "NotConnected"}),
        %({"connection-status": "Connected"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait"],
        no_waiting.merge({"CONDUIT_CONNECT_GRACE_POLLS" => "3"}),
      )

      result.exit_code.should eq(0)
      result.stdout.should contain(%("outcome": "connected"))
    end
  end

  it "stops waiting on an attempt that never registers" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "NotConnected"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait"],
        no_waiting.merge({"CONDUIT_CONNECT_GRACE_POLLS" => "2"}),
      )

      result.exit_code.should eq(1)
      status_calls = sandbox.calls.count(&.includes?("get-connection-status"))
      status_calls.should eq(2)
    end
  end

  # Giving up watching says nothing about whether the attempt will succeed,
  # so it must not present as a failure or share its exit code.
  it "separates giving up watching from failing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "WaitingForIdentity"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait"],
        no_waiting.merge({"CONDUIT_CONNECT_TIMEOUT" => "0"}),
      )

      result.exit_code.should eq(3)
      result.stdout.should contain(%("outcome": "timed-out"))
      result.stderr.should contain("may still be waiting for sign-in")
    end
  end

  it "accepts a timeout on the command line" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "WaitingForIdentity"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait", "--timeout", "0"],
        no_waiting,
      )

      result.exit_code.should eq(3)
    end
  end

  it "reports a rejected attempt rather than polling after it" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "connect",
        %({"status": "Error", "message": "Profile not found"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Nowhere", "--wait"],
        no_waiting.merge({"FAKE_VPN_EXIT_CONNECT" => "1"}),
      )

      result.exit_code.should eq(1)
      result.stderr.should contain("Profile not found")
      sandbox.calls.count(&.includes?("get-connection-status")).should eq(0)
    end
  end

  it "will not poll without knowing which profile to poll" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["connect", "--wait"], no_waiting)

      result.exit_code.should eq(2)
      result.stderr.should contain("--profile-name")
      sandbox.calls.should be_empty
    end
  end

  # Conduit's own flags must not reach the client, which would reject them.
  it "keeps its own flags out of what it forwards" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "Connected"}),
      )

      SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha", "--wait", "--timeout", "30"],
        no_waiting,
      )

      connect_call = sandbox.calls.find!(&.includes?("ARGS=connect"))
      connect_call.should end_with("ARGS=connect --profile-name Alpha")
    end
  end
end

describe "disconnect --wait" do
  it "reports a teardown the client itself reports silently" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("disconnect", "")
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "Disconnecting"}),
        %({"connection-status": "NotConnected"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["disconnect", "--profile-name", "Alpha", "--wait"],
        no_waiting,
      )

      result.exit_code.should eq(0)
      result.stdout.should contain(%("outcome": "disconnected"))
      result.stderr.should contain("Alpha disconnected")
    end
  end

  it "stops waiting on a teardown that never completes" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("disconnect", "")
      sandbox.respond(
        "get-connection-status",
        %({"connection-status": "Disconnecting"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["disconnect", "--profile-name", "Alpha", "--wait"],
        no_waiting.merge({"CONDUIT_CONNECT_TIMEOUT" => "0"}),
      )

      result.exit_code.should eq(3)
    end
  end
end
