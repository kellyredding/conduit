require "../spec_helper"

private alias Config = ConduitVPN::Config

describe ConduitVPN::Config do
  describe "resolution order" do
    it "falls back to a compiled default" do
      SpecHelper.with_root do
        resolved = Config.resolve("client-path")
        resolved.source.should eq(Config::Source::Default)
        resolved.value.should contain("aws-vpn-client")
      end
    end

    it "prefers the config file over a default" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"connect-timeout": "45"}))

        resolved = Config.resolve("connect-timeout")
        resolved.value.should eq("45")
        resolved.source.should eq(Config::Source::File)
      end
    end

    it "prefers the environment over the config file" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"connect-timeout": "45"}))

        SpecHelper.with_env({"CONDUIT_CONNECT_TIMEOUT" => "60"}) do
          resolved = Config.resolve("connect-timeout")
          resolved.value.should eq("60")
          resolved.source.should eq(Config::Source::Env)
        end
      end
    end

    it "prefers a flag over everything else" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"connect-timeout": "45"}))

        SpecHelper.with_env({"CONDUIT_CONNECT_TIMEOUT" => "60"}) do
          begin
            Config.override("connect-timeout", "5")
            resolved = Config.resolve("connect-timeout")
            resolved.value.should eq("5")
            resolved.source.should eq(Config::Source::Flag)
          ensure
            Config.clear_overrides
          end
        end
      end
    end
  end

  describe "the config file" do
    it "treats an absent file as everything being default" do
      SpecHelper.with_root do
        Config.effective.all? { |entry| entry.source.default? }.should be_true
      end
    end

    it "accepts a file holding only some of the settings" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"connect-timeout": "45"}))

        by_name = Config.effective.to_h { |entry| {entry.key.name, entry} }
        by_name["connect-timeout"].source.should eq(Config::Source::File)
        by_name["poll-interval-active"].source.should eq(Config::Source::Default)
      end
    end

    it "reads a number written without quotes" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"connect-timeout": 45}))
        Config.int("connect-timeout").should eq(45)
      end
    end

    it "ignores keys it does not recognize" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %({"nonsense": "x", "connect-timeout": "45"}))
        Config.get("connect-timeout").should eq("45")
      end
    end

    # A settings file is a poor reason to refuse to report connection status,
    # so a broken one degrades to defaults and says so on stderr.
    it "degrades to defaults when the file is not readable as settings" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, "{ this is not json")
        Config.resolve("connect-timeout").source.should eq(Config::Source::Default)
      end
    end

    it "degrades to defaults when the file is not an object" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, %(["nope"]))
        Config.resolve("connect-timeout").source.should eq(Config::Source::Default)
      end
    end
  end

  describe ".set and .unset" do
    it "creates the file on first write" do
      SpecHelper.with_root do |root|
        File.exists?((root / "config.json").to_s).should be_false

        Config.set("connect-timeout", "45")

        File.exists?((root / "config.json").to_s).should be_true
        Config.get("connect-timeout").should eq("45")
      end
    end

    it "leaves other settings untouched" do
      SpecHelper.with_root do
        Config.set("connect-timeout", "45")
        Config.set("poll-interval-active", "1")

        Config.get("connect-timeout").should eq("45")
        Config.get("poll-interval-active").should eq("1")
      end
    end

    it "restores the default on unset" do
      SpecHelper.with_root do
        Config.set("connect-timeout", "45")
        Config.unset("connect-timeout")

        Config.resolve("connect-timeout").source.should eq(Config::Source::Default)
        Config.get("connect-timeout").should eq("120")
      end
    end

    it "refuses a setting that does not exist" do
      SpecHelper.with_root do
        expect_raises(Config::UnknownKey, "no-such-setting") do
          Config.set("no-such-setting", "x")
        end
      end
    end
  end

  describe "typed reads" do
    it "reports a value that should be a number but is not" do
      SpecHelper.with_env({"CONDUIT_CONNECT_TIMEOUT" => "soon"}) do
        expect_raises(Config::NotAnInteger, "connect-timeout") do
          Config.int("connect-timeout")
        end
      end
    end

    it "converts seconds settings to spans" do
      SpecHelper.with_env({"CONDUIT_CONNECT_TIMEOUT" => "45"}) do
        Config.seconds("connect-timeout").should eq(45.seconds)
      end
    end
  end

  describe "derived paths" do
    # A hardcoded default would silently detach the client's log directory
    # from a relocated installation.
    it "derives the client home from the resolved root" do
      SpecHelper.with_env({
        "CONDUIT_ROOT"        => "/somewhere/else",
        "CONDUIT_CLIENT_HOME" => nil,
      }) do
        Config.client_home.should eq(Path.new("/somewhere/else/client-home"))
      end
    end

    it "expands a leading tilde, which a config file would not have expanded" do
      SpecHelper.with_env({"CONDUIT_CLIENT_HOME" => "~/vpn-logs"}) do
        Config.client_home.should eq(Path.home / "vpn-logs")
      end
    end
  end

  describe ".example_json" do
    it "is valid JSON covering every setting" do
      SpecHelper.with_root do
        parsed = JSON.parse(Config.example_json).as_h
        parsed.keys.sort.should eq(Config.keys.map(&.name).sort)
      end
    end

    # Written so it can be copied to config.json and edited, which rules out
    # comments however useful they would be.
    it "can be copied straight into place and read back" do
      SpecHelper.with_root do |root|
        SpecHelper.write_config(root, Config.example_json)
        Config.effective.all? { |entry| entry.source.file? }.should be_true
      end
    end
  end
end
