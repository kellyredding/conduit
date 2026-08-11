require "../spec_helper"

describe "status" do
  # The client cannot produce this view: it lists profiles and connections
  # separately, and only non-disconnected profiles appear in the second.
  it "merges profiles with the connections that exist" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", <<-JSON)
      [{"profile-name": "Alpha", "auth-type": "saml"},
       {"profile-name": "Bravo", "auth-type": "saml"},
       {"profile-name": "Charlie", "auth-type": "saml"}]
      JSON
      sandbox.respond("list-connections", <<-JSON)
      [{"profile-name": "Bravo", "connection-status": "Connected",
        "last-updated-at": "2026-01-01T12:00:00-05:00"}]
      JSON

      result = SpecHelper.run(sandbox, ["status"])

      result.exit_code.should eq(0)
      result.stdout.should match(/Alpha\s+not connected/)
      result.stdout.should match(/Bravo\s+connected/)
      result.stdout.should match(/Charlie\s+not connected/)
    end
  end

  it "reports a transitional connection as what it is" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", %([{"profile-name": "Alpha"}]))
      sandbox.respond("list-connections", <<-JSON)
      [{"profile-name": "Alpha", "connection-status": "WaitingForIdentity"}]
      JSON

      result = SpecHelper.run(sandbox, ["status"])

      result.stdout.should match(/Alpha\s+waiting for sign-in/)
    end
  end

  it "shows a state it cannot name rather than guessing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", %([{"profile-name": "Alpha"}]))
      sandbox.respond("list-connections", <<-JSON)
      [{"profile-name": "Alpha", "connection-status": "Teleporting"}]
      JSON

      result = SpecHelper.run(sandbox, ["status"])

      result.exit_code.should eq(0)
      result.stdout.should contain("Teleporting")
    end
  end

  it "says so plainly when nothing is installed" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", "[]")
      sandbox.respond("list-connections", "[]")

      result = SpecHelper.run(sandbox, ["status"])

      result.exit_code.should eq(0)
      result.stdout.should contain("No profiles are installed")
    end
  end

  describe "--json" do
    it "emits one object per profile with hyphenated keys" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", <<-JSON)
        [{"profile-name": "Alpha"}, {"profile-name": "Prod-Bravo"}]
        JSON
        sandbox.respond("list-connections", <<-JSON)
        [{"profile-name": "Prod-Bravo", "connection-status": "Connected",
          "last-updated-at": "2026-01-01T12:00:00-05:00"}]
        JSON

        result = SpecHelper.run(sandbox, ["status", "--json"])

        rows = JSON.parse(result.stdout).as_a
        rows.size.should eq(2)

        alpha = rows.find! { |row| row["profile-name"] == "Alpha" }
        alpha["connected"].as_bool.should be_false
        alpha["sensitive"].as_bool.should be_false
        alpha["updated-at"].raw.should be_nil

        bravo = rows.find! { |row| row["profile-name"] == "Prod-Bravo" }
        bravo["connected"].as_bool.should be_true
        bravo["sensitive"].as_bool.should be_true
      end
    end

    it "emits an empty array when nothing is installed" do
      SpecHelper.sandbox do |sandbox|
        sandbox.respond("list-profiles", "[]")
        sandbox.respond("list-connections", "[]")

        result = SpecHelper.run(sandbox, ["status", "--json"])

        JSON.parse(result.stdout).as_a.should be_empty
      end
    end
  end

  it "reports a client failure rather than an empty listing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond(
        "list-profiles",
        %({"status": "Error", "message": "Daemon unavailable"}),
      )

      result = SpecHelper.run(
        sandbox,
        ["status"],
        {"FAKE_VPN_EXIT_LIST_PROFILES" => "1"},
      )

      result.exit_code.should eq(1)
      result.stderr.should contain("Daemon unavailable")
    end
  end

  it "reports unreadable output rather than crashing" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", "this is not json")

      result = SpecHelper.run(sandbox, ["status"])

      result.exit_code.should eq(1)
      result.stderr.should contain("could not read the client's response")
    end
  end
end

describe "status column layout" do
  # A column of dashes under a heading is worse than no column: it takes space
  # to say nothing.
  it "omits the timestamp column when nothing is connected" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", %([{"profile-name": "Alpha"}]))
      sandbox.respond("list-connections", "[]")

      result = SpecHelper.run(sandbox, ["status"])

      result.stdout.should_not contain("UPDATED")
      result.stdout.should_not contain("—")
    end
  end

  it "shows the timestamp column as soon as one connection has one" do
    SpecHelper.sandbox do |sandbox|
      sandbox.respond("list-profiles", <<-JSON)
      [{"profile-name": "Alpha"}, {"profile-name": "Bravo"}]
      JSON
      sandbox.respond("list-connections", <<-JSON)
      [{"profile-name": "Bravo", "connection-status": "Connected",
        "last-updated-at": "2026-01-01T12:00:00-05:00"}]
      JSON

      result = SpecHelper.run(sandbox, ["status"])

      result.stdout.should contain("UPDATED")
      result.stdout.should contain("2026-01-01")
      # The disconnected row still gets a placeholder so columns line up.
      result.stdout.should contain("—")
    end
  end
end
