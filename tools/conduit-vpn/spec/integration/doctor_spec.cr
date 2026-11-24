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

      result.stdout.lines.size.should eq(7)
    end
  end

  # Says why the last session ended, when the client ended it for a reason —
  # the line that distinguishes "this machine is misconfigured" from "the
  # client stopped a working tunnel on purpose".
  #
  # Reported even when there is nothing to report, like every other check
  # here: one that appears only on failure is one nobody knows exists until
  # the day it does.
  it "reports the last teardown, and says so when there was none" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", "[]")

      result = SpecHelper.run(sandbox, ["doctor"])

      result.stdout.should contain("last teardown")
      result.stdout.should contain("none recorded")
    end
  end

  # A warning is not a reason to stop looking. Gating the client checks on
  # "everything so far passed" meant an unrelated advisory silenced them.
  it "keeps checking the client even when an advisory check warns" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", %([{"profile-name": "Alpha"}]))

      result = SpecHelper.run(sandbox, ["doctor"])

      result.stdout.should contain("client responds")
      result.stdout.should contain("1 installed")
    end
  end

  it "stops short of asking the client anything once a precondition fails" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["doctor"],
        {"CONDUIT_CLIENT_PATH" => "/nonexistent/aws-vpn-client"},
      )

      result.stdout.should contain("FAIL")
      result.stdout.should_not contain("client responds")
      sandbox.calls.should be_empty
    end
  end

  describe "the install" do
    it "warns, without failing, when there is no install record or it is unreadable" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        result = SpecHelper.run(sandbox, ["doctor"])
        result.exit_code.should eq(0)
        result.stdout.should match(/^warn\s+install\s+no install record at .*installed-manifest\.json; `conduit-vpn update`/m)
        result.stdout.should_not contain("installed app")

        File.write(sandbox.root / "installed-manifest.json", "{")
        SpecHelper.run(sandbox, ["doctor"]).stdout.should match(/^warn\s+install\s+unreadable install record/m)
      end
    end

    it "reports the install record install.sh wrote" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        sandbox.write_manifest(dirty: true)
        result = SpecHelper.run(sandbox, ["doctor"])
        result.stdout.should match(/^ok\s+install\s+Conduit 0\.1\.0 \(abc123def456, uncommitted changes\), built /m)
        result.stdout.should contain("built 2026-11-24T10:00:00Z, signed by Conduit Release Signing\n")
      end
    end

    it "checks the installed app, its signer, the CLI and Launch Services against the record" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        sandbox.write_manifest(sha256: sandbox.install_cli)
        app = sandbox.install_app("abc123def456")
        SpecHelper.write_executable(sandbox.lsregister, <<-SH)
          #!/bin/sh
          echo "path:          #{app} (0x1a2b)"
          echo "path:          /tmp/build/Debug/Conduit.app (0x3c4d)"
          echo "path:          /Applications/Other.app (0x5e6f)"
          SH

        result = SpecHelper.run(sandbox, ["doctor"])
        result.stdout.should match(/^ok\s+installed app\s+Conduit\.app 0\.1\.0 \(abc123def456\)$/m)
        result.stdout.should match(/^FAIL\s+app signer\s+Conduit\.app is ad hoc or unsigned/m)
        result.stdout.should match(/^ok\s+installed cli\s+.*bin\/conduit-vpn is the recorded build$/m)
        result.stdout.should match(/^ok\s+registration\s+Launch Services knows #{Regex.escape(app.to_s)}$/m)
        result.stdout.should match(/^warn\s+registration\s+another Conduit\.app is registered: \/tmp\/build\/Debug\/Conduit\.app$/m)
        result.stdout.should_not contain("Other.app")
        result.exit_code.should eq(1)
      end
    end

    it "fails an installed app or CLI that is not the recorded build" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        sandbox.write_manifest(commit: "abc123def456", sha256: "00")
        sandbox.install_cli
        sandbox.install_app("fedcba987654")

        result = SpecHelper.run(sandbox, ["doctor"])
        result.exit_code.should eq(1)
        result.stdout.should match(/^FAIL\s+installed app\s+Conduit\.app is from fedcba987654, the install record from abc123def456/m)
        result.stdout.should match(/^FAIL\s+installed cli\s+.* is not the build the install record names/m)
        result.stdout.should match(/^warn\s+registration\s+could not ask Launch Services/m)

        sandbox.install_app(nil)
        SpecHelper.run(sandbox, ["doctor"]).stdout.should match(/^FAIL\s+installed app\s+Conduit\.app carries no build commit/m)
      end
    end

    it "fails a missing app or CLI, and an app that is a link into a build" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        sandbox.write_manifest
        result = SpecHelper.run(sandbox, ["doctor"])
        result.stdout.should match(/^FAIL\s+installed app\s+.*Conduit\.app is missing/m)
        result.stdout.should match(/^FAIL\s+installed cli\s+.*bin\/conduit-vpn is missing/m)
        result.stdout.should_not contain("app signer")

        build = sandbox.root / "build" / "Conduit.app"
        Dir.mkdir_p(build)
        Dir.mkdir_p(sandbox.applications)
        File.symlink(build, sandbox.applications / "Conduit.app")
        SpecHelper.run(sandbox, ["doctor"]).stdout
          .should match(/^FAIL\s+installed app\s+.*Conduit\.app is a link to .*build\/Conduit\.app, not an installed copy/m)
      end
    end
  end

  describe "--explain" do
    it "describes the address-translation failure and names the workaround" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(sandbox, ["doctor", "--explain"])

        result.exit_code.should eq(0)
        result.stdout.should contain("NAT64")
        result.stdout.should contain("networksetup")
        sandbox.calls.should be_empty
      end
    end
  end
end
