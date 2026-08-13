require "../spec_helper"

describe "passthrough" do
  it "returns the client's stdout unchanged" do
    payload = <<-JSON
    [
      {
        "profile-name": "Alpha",
        "owned-by": "someone",
        "auth-type": "saml",
        "imported-at": "2026-01-01T00:00:00-05:00"
      }
    ]
    JSON

    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", payload)

      result = SpecHelper.run(sandbox, ["list-profiles"])

      result.exit_code.should eq(0)
      result.stdout.should eq(payload)
    end
  end

  it "forwards every argument in order" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(
        sandbox,
        ["get-connection-status", "--profile-name", "Bravo", "--show-details"],
      )

      sandbox.calls.size.should eq(1)
      sandbox.calls.first.should end_with(
        "ARGS=get-connection-status --profile-name Bravo --show-details"
      )
    end
  end

  # The entire reason this wrapper exists. The client derives its log path
  # from HOME and aborts when that path contains a symlink, so a run that
  # forgot to override HOME would crash rather than misbehave subtly.
  it "runs the client with the configured HOME, not the caller's" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["list-profiles"])

      sandbox.calls.first.should start_with("HOME=#{sandbox.client_home}")
    end
  end

  it "creates the client home on first use" do
    SpecHelper.sandbox do |sandbox|
      Dir.exists?(sandbox.client_home.to_s).should be_false

      SpecHelper.run(sandbox, ["list-profiles"])

      Dir.exists?((sandbox.client_home / ".config").to_s).should be_true
    end
  end

  it "propagates a non-zero exit code from the client" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "connect",
        %({"status": "Error", "message": "Profile not found"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Nonexistent"],
        {"FAKE_VPN_EXIT_CONNECT" => "1"},
      )

      result.exit_code.should eq(1)
      result.stdout.should contain("Profile not found")
    end
  end

  it "distinguishes the client's usage exit code from its failure code" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["connect", "--bogus-flag"],
        {"FAKE_VPN_EXIT_CONNECT" => "2"},
      )

      result.exit_code.should eq(2)
    end
  end
end

describe "unrecognized input" do
  it "names the offending command instead of forwarding it" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["list-porfiles"])

      result.exit_code.should eq(2)
      result.stderr.should contain("list-porfiles")
      sandbox.calls.should be_empty
    end
  end

  it "prints usage to stderr when invoked with no command" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, [] of String)

      result.exit_code.should eq(2)
      result.stderr.should contain("Usage:")
      result.stdout.should be_empty
    end
  end
end

describe "client availability" do
  it "explains a missing client rather than reporting a failed command" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["list-profiles"],
        {"CONDUIT_CLIENT_PATH" => "/nonexistent/aws-vpn-client"},
      )

      result.exit_code.should eq(1)
      result.stderr.should contain("not found")
      result.stderr.should contain("/nonexistent/aws-vpn-client")
    end
  end

  # Catching this here turns an opaque crash inside the client into a
  # message naming the directory and how to move it.
  it "refuses to run when the client home is reached through a symlink" do
    SpecHelper.sandbox do |sandbox|
      elsewhere = sandbox.root / "elsewhere"
      Dir.mkdir_p(elsewhere.to_s)
      Dir.mkdir_p(sandbox.client_home.to_s)
      File.symlink(elsewhere.to_s, (sandbox.client_home / ".config").to_s)

      result = SpecHelper.run(sandbox, ["list-profiles"])

      result.exit_code.should eq(1)
      result.stderr.should contain("must be a real directory")
      result.stderr.should contain("config set client-home")
      sandbox.calls.should be_empty
    end
  end
end

describe "conduit's own commands" do
  it "reports its version" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["--version"])

      result.exit_code.should eq(0)
      result.stdout.strip.should eq(ConduitVPN::VERSION)
      sandbox.calls.should be_empty
    end
  end

  it "lists both its own commands and the forwarded ones" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["--help"])

      result.exit_code.should eq(0)
      result.stdout.should contain("list-profiles")
      result.stdout.should contain("version")
      sandbox.calls.should be_empty
    end
  end
end

# Help for the two commands Conduit extends used to be forwarded straight to the
# client, which documents its own flags and knows nothing about Conduit's. The
# one place a caller looks to learn whether --wait exists therefore said it did
# not, and anything reasoning from that would go back to polling by hand.
describe "help for an extended command" do
  it "documents the flags Conduit adds to connect" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["connect", "--help"])

      result.exit_code.should eq(0)
      result.stdout.should contain("--wait")
      result.stdout.should contain("--yes")
      result.stdout.should contain("--timeout")
    end
  end

  # The distinction the exit codes exist to carry, stated where somebody
  # deciding whether to retry will read it.
  it "says a timeout is not a failure" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["connect", "--help"])

      result.stdout.should contain("not a failure")
    end
  end

  it "documents the flags Conduit adds to disconnect" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["disconnect", "--help"])

      result.exit_code.should eq(0)
      result.stdout.should contain("--wait")
    end
  end

  # Conduit's half is printed first and then the client is asked for its own, so
  # the command answers the whole question rather than half of it.
  it "still asks the client for its own options" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["connect", "--help"])

      sandbox.calls.size.should eq(1)
      sandbox.calls.first.should end_with("ARGS=connect --help")
    end
  end

  # Asking for help must never start a connection, whatever else is on the line.
  it "does not connect when help is requested alongside a profile" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(
        sandbox, ["connect", "--profile-name", "Alpha", "--help"]
      )

      sandbox.calls.size.should eq(1)
      sandbox.calls.first.should end_with("ARGS=connect --help")
    end
  end

  # config is Conduit's own, so there is no client half to append — but it used
  # to answer a request for help with a usage error, which is the same trap in a
  # different command.
  it "answers config --help with help rather than a usage error" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["config", "--help"])

      result.exit_code.should eq(0)
      result.stdout.should contain("describe")
      result.stdout.should contain("example")
      sandbox.calls.should be_empty
    end
  end

  # Asking how to write a setting must not write one.
  it "does not apply a setting when help is requested alongside it" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox, ["config", "set", "connect-timeout", "45", "--help"]
      )

      result.exit_code.should eq(0)
      File.exists?(sandbox.config_file.to_s).should be_false
    end
  end
end
