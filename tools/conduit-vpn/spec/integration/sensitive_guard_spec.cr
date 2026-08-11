require "../spec_helper"

describe "the sensitive-profile guard" do
  # The rule used to be enforced by whoever read the documentation choosing to
  # honor it. What matters most here is that a refusal reaches the client not
  # as a cancelled connection but as no connection at all.
  it "refuses without confirmation and issues nothing to the client" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["connect", "--profile-name", "Prod-Alpha"])

      result.exit_code.should eq(1)
      result.stderr.should contain("Prod-Alpha")
      result.stderr.should contain("--yes")
      sandbox.calls.should be_empty
    end
  end

  it "proceeds once confirmed" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Prod-Alpha", "--yes"],
      )

      result.exit_code.should eq(0)
      sandbox.calls.size.should eq(1)
    end
  end

  it "keeps the confirmation flag out of what it forwards" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      SpecHelper.run(sandbox, ["connect", "--profile-name", "Prod-Alpha", "--yes"])

      sandbox.calls.first.should end_with("ARGS=connect --profile-name Prod-Alpha")
    end
  end

  it "leaves unmatched profiles alone" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("connect", %({"status": "WaitingForIdentity"}))

      result = SpecHelper.run(sandbox, ["connect", "--profile-name", "Alpha"])

      result.exit_code.should eq(0)
      sandbox.calls.size.should eq(1)
    end
  end

  it "guards whatever a replacement pattern names" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha"],
        {"CONDUIT_SENSITIVE_PATTERN" => "(?i)alpha"},
      )

      result.exit_code.should eq(1)
      result.stderr.should contain("Alpha")
      sandbox.calls.should be_empty
    end
  end

  it "reports an unusable pattern instead of quietly guarding nothing" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["connect", "--profile-name", "Alpha"],
        {"CONDUIT_SENSITIVE_PATTERN" => "(unclosed"},
      )

      result.exit_code.should eq(1)
      result.stderr.should contain("not a valid expression")
      sandbox.calls.should be_empty
    end
  end

  # Disconnecting is not destructive in the way connecting is, and needing
  # confirmation to stop something would be an obstacle at the worst moment.
  it "does not stand in the way of disconnecting" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("disconnect", "")

      result = SpecHelper.run(
        sandbox,
        ["disconnect", "--profile-name", "Prod-Alpha"],
      )

      result.exit_code.should eq(0)
      sandbox.calls.size.should eq(1)
    end
  end

  it "marks which profiles need confirmation in a status listing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", <<-JSON)
      [{"profile-name": "Alpha", "auth-type": "saml"},
       {"profile-name": "Prod-Bravo", "auth-type": "saml"}]
      JSON
      sandbox.respond("list-connections", "[]")

      result = SpecHelper.run(sandbox, ["status"])

      result.stdout.should match(/^!\s+Prod-Bravo/m)
      result.stdout.should match(/^\s+Alpha/m)
      result.stdout.should contain("needs --yes to connect")
    end
  end
end
