require "../spec_helper"

describe ConduitVPN::Paths do
  describe ".root" do
    it "sits under the home directory by default" do
      SpecHelper.with_env({"CONDUIT_ROOT" => nil}) do
        ConduitVPN::Paths.root.should eq(Path.home / ".conduit")
      end
    end

    it "honors CONDUIT_ROOT" do
      SpecHelper.with_env({"CONDUIT_ROOT" => "/somewhere/else"}) do
        ConduitVPN::Paths.root.should eq(Path.new("/somewhere/else"))
      end
    end
  end

  describe "derived paths" do
    it "hangs off the resolved root rather than the default one" do
      SpecHelper.with_env({"CONDUIT_ROOT" => "/somewhere/else"}) do
        ConduitVPN::Paths.bin_dir.should eq(Path.new("/somewhere/else/bin"))
        ConduitVPN::Paths.log_dir.should eq(Path.new("/somewhere/else/logs"))
        ConduitVPN::Paths.config_file
          .should eq(Path.new("/somewhere/else/config.json"))
        ConduitVPN::Paths.example_config_file
          .should eq(Path.new("/somewhere/else/config.example.json"))
      end
    end
  end

  describe ".config_file" do
    it "honors CONDUIT_CONFIG independently of the root" do
      SpecHelper.with_env({
        "CONDUIT_ROOT"   => "/somewhere/else",
        "CONDUIT_CONFIG" => "/tmp/other.json",
      }) do
        ConduitVPN::Paths.config_file.should eq(Path.new("/tmp/other.json"))
      end
    end
  end
end
