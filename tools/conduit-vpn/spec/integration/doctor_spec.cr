require "../spec_helper"

describe "doctor" do
  it "passes on a working setup" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", <<-JSON)
      [{"profile-name": "Alpha"}, {"profile-name": "Bravo"}]
      JSON

      result = SpecHelper.run(sandbox, ["doctor"])

      result.exit_code.should eq(0)
      result.stdout.should contain("client binary")
      result.stdout.should contain("client home")
      result.stdout.should contain("2 installed")
      result.stdout.should_not contain("FAIL")
    end
  end

  # Diagnostic output is the single most likely thing to be pasted somewhere
  # public, so it reports how many profiles exist and never which.
  it "counts profiles without naming them" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", <<-JSON)
      [{"profile-name": "Alpha"}, {"profile-name": "Prod-Bravo"}]
      JSON

      result = SpecHelper.run(sandbox, ["doctor"])

      result.stdout.should contain("2 installed")
      result.stdout.should_not contain("Alpha")
      result.stdout.should_not contain("Prod-Bravo")
    end
  end

  it "fails when the client is not installed" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["doctor"],
        {"CONDUIT_CLIENT_PATH" => "/nonexistent/aws-vpn-client"},
      )

      result.exit_code.should eq(1)
      result.stdout.should contain("FAIL")
      result.stdout.should contain("not found")
    end
  end

  it "fails when the client home is reached through a symlink" do
    SpecHelper.sandbox do |sandbox|
      elsewhere = sandbox.root / "elsewhere"
      Dir.mkdir_p(elsewhere.to_s)
      Dir.mkdir_p(sandbox.client_home.to_s)
      File.symlink(elsewhere.to_s, (sandbox.client_home / ".config").to_s)

      result = SpecHelper.run(sandbox, ["doctor"])

      result.exit_code.should eq(1)
      result.stdout.should contain("FAIL")
      result.stdout.should contain("symlink")
    end
  end

  it "reports what the client said when it refuses to answer" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "list-profiles",
        %({"status": "Error", "message": "Daemon unavailable"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["doctor"],
        {"FAKE_VPN_EXIT_LIST_PROFILES" => "1"},
      )

      result.exit_code.should eq(1)
      result.stdout.should contain("Daemon unavailable")
    end
  end

  # Conduit does not provision profiles, so an empty list is a legitimate
  # state that simply leaves nothing to connect to.
  it "warns rather than fails when no profiles are installed" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", "[]")

      result = SpecHelper.run(sandbox, ["doctor"])

      result.exit_code.should eq(0)
      result.stdout.should contain("warn")
      result.stdout.should contain("none installed")
    end
  end

  # Every problem at once, rather than only the first: whoever is fixing this
  # wants the whole list.
  it "reports later checks even after an earlier one passes" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", "[]")

      result = SpecHelper.run(sandbox, ["doctor"])

      result.stdout.lines.size.should eq(4)
    end
  end

  it "stops short of asking the client anything once a precondition fails" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["doctor"],
        {"CONDUIT_CLIENT_PATH" => "/nonexistent/aws-vpn-client"},
      )

      result.stdout.lines.size.should eq(2)
      sandbox.calls.should be_empty
    end
  end
end
