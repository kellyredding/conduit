require "../spec_helper"

describe ConduitVPN::Config do
  describe ".resolve" do
    it "reports a compiled default as coming from the default layer" do
      SpecHelper.with_env({"CONDUIT_CLIENT_PATH" => nil}) do
        resolved = ConduitVPN::Config.resolve("client-path")
        resolved.source.should eq(ConduitVPN::Config::Source::Default)
        resolved.value.should contain("aws-vpn-client")
      end
    end

    it "prefers an environment variable over the default" do
      SpecHelper.with_env({"CONDUIT_CLIENT_PATH" => "/opt/elsewhere/client"}) do
        resolved = ConduitVPN::Config.resolve("client-path")
        resolved.value.should eq("/opt/elsewhere/client")
        resolved.source.should eq(ConduitVPN::Config::Source::Env)
      end
    end

    it "raises for a setting that does not exist" do
      expect_raises(ConduitVPN::Config::UnknownKey, "no-such-setting") do
        ConduitVPN::Config.resolve("no-such-setting")
      end
    end
  end

  describe "client-home" do
    # The default is derived rather than literal, so an overridden root has
    # to carry it. Hardcoding the default would silently detach the client's
    # log directory from a relocated installation.
    it "derives its default from the resolved root" do
      SpecHelper.with_env({
        "CONDUIT_ROOT"        => "/somewhere/else",
        "CONDUIT_CLIENT_HOME" => nil,
      }) do
        ConduitVPN::Config.client_home
          .should eq(Path.new("/somewhere/else/client-home"))
      end
    end

    it "honors its own override independently of the root" do
      SpecHelper.with_env({
        "CONDUIT_ROOT"        => "/somewhere/else",
        "CONDUIT_CLIENT_HOME" => "/var/tmp/client-home",
      }) do
        ConduitVPN::Config.client_home
          .should eq(Path.new("/var/tmp/client-home"))
      end
    end
  end

  describe ".path" do
    # A value typed with a leading tilde reaches the resolver unexpanded
    # when it comes from a file rather than a shell.
    it "expands a leading tilde" do
      SpecHelper.with_env({"CONDUIT_CLIENT_HOME" => "~/vpn-logs"}) do
        ConduitVPN::Config.client_home.should eq(Path.home / "vpn-logs")
      end
    end
  end

  describe ".effective" do
    it "reports every setting with the layer it came from" do
      SpecHelper.with_env({
        "CONDUIT_CLIENT_PATH" => "/opt/elsewhere/client",
        "CONDUIT_CLIENT_HOME" => nil,
      }) do
        effective = ConduitVPN::Config.effective
        effective.map(&.key.name)
          .should eq(["client-path", "client-home"])
        effective.map(&.source).should eq([
          ConduitVPN::Config::Source::Env,
          ConduitVPN::Config::Source::Default,
        ])
      end
    end
  end
end
