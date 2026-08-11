require "../spec_helper"

describe "config" do
  it "shows every setting with the layer it came from" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["config"])

      result.exit_code.should eq(0)
      result.stdout.should contain("client-path")
      result.stdout.should contain("connect-timeout")
      # The source column is the reason the command exists: "why is it doing
      # that" is answered by which layer won, not by the value.
      result.stdout.should contain("(default)")
    end
  end

  it "attributes a value that came from the environment" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(
        sandbox,
        ["config"],
        {"CONDUIT_CONNECT_TIMEOUT" => "45"},
      )

      result.stdout.should match(/connect-timeout\s+45\s+\(env\)/)
    end
  end

  describe "set" do
    it "creates the file on first write" do
      SpecHelper.sandbox do |sandbox|
        config = sandbox.root / "config.json"
        File.exists?(config.to_s).should be_false

        result = SpecHelper.run(sandbox, ["config", "set", "connect-timeout", "45"])

        result.exit_code.should eq(0)
        File.exists?(config.to_s).should be_true
        JSON.parse(File.read(config.to_s))["connect-timeout"].should eq("45")
      end
    end

    it "records only what was changed" do
      SpecHelper.sandbox do |sandbox|
        SpecHelper.run(sandbox, ["config", "set", "connect-timeout", "45"])

        written = JSON.parse(File.read((sandbox.root / "config.json").to_s)).as_h
        written.keys.should eq(["connect-timeout"])
      end
    end

    # Writing the file does not necessarily change the effective value, and a
    # silent no-op here sends someone hunting for a long time.
    it "warns when a higher layer still outranks the file" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(
          sandbox,
          ["config", "set", "connect-timeout", "45"],
          {"CONDUIT_CONNECT_TIMEOUT" => "99"},
        )

        result.exit_code.should eq(0)
        result.stderr.should contain("outranks")
        result.stderr.should contain("env")
      end
    end

    it "refuses a setting that does not exist" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(sandbox, ["config", "set", "nonsense", "1"])

        result.exit_code.should eq(1)
        result.stderr.should contain("unknown setting")
        File.exists?((sandbox.root / "config.json").to_s).should be_false
      end
    end

    it "reports a missing value rather than writing an empty one" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(sandbox, ["config", "set", "connect-timeout"])

        result.exit_code.should eq(2)
        File.exists?((sandbox.root / "config.json").to_s).should be_false
      end
    end
  end

  describe "get" do
    it "prints the value alone, for scripts" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(
          sandbox,
          ["config", "get", "connect-timeout"],
          {"CONDUIT_CONNECT_TIMEOUT" => "45"},
        )

        result.exit_code.should eq(0)
        result.stdout.strip.should eq("45")
      end
    end
  end

  describe "unset" do
    it "returns a setting to its default" do
      SpecHelper.sandbox do |sandbox|
        SpecHelper.run(sandbox, ["config", "set", "connect-timeout", "45"])

        result = SpecHelper.run(sandbox, ["config", "unset", "connect-timeout"])

        result.exit_code.should eq(0)
        result.stdout.should contain("120")
        result.stdout.should contain("default")
      end
    end
  end

  describe "describe" do
    it "explains each setting and names its environment variable" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(sandbox, ["config", "describe"])

        result.exit_code.should eq(0)
        result.stdout.should contain("CONDUIT_CLIENT_HOME")
        result.stdout.should contain("sensitive-profile-pattern")
      end
    end
  end

  describe "example" do
    # Written to be copied into place and edited, which is why it carries no
    # comments however useful they would be.
    it "emits valid JSON covering every setting" do
      SpecHelper.sandbox do |sandbox|
        result = SpecHelper.run(sandbox, ["config", "example"])

        result.exit_code.should eq(0)
        parsed = JSON.parse(result.stdout).as_h
        parsed.keys.should contain("client-home")
        parsed.keys.should contain("connect-grace-polls")
      end
    end
  end

  it "names an action it does not recognize" do
    SpecHelper.sandbox do |sandbox|
      result = SpecHelper.run(sandbox, ["config", "reticulate"])

      result.exit_code.should eq(2)
      result.stderr.should contain("reticulate")
    end
  end

  it "keeps working when the file cannot be read as settings" do
    SpecHelper.sandbox do |sandbox|
      File.write((sandbox.root / "config.json").to_s, "{ not json")

      result = SpecHelper.run(sandbox, ["config"])

      result.exit_code.should eq(0)
      result.stderr.should contain("ignoring")
      result.stdout.should contain("(default)")
    end
  end
end
