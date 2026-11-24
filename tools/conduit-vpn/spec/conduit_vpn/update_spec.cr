require "../spec_helper"

private alias Update = ConduitVPN::Commands::Update

describe ConduitVPN::Commands::Update do
  describe ".parse" do
    it "installs the latest release with no arguments" do
      options = Update.parse([] of String)
      options.local.should be_false
      options.version.should be_nil
      options.preview.should be_false
      options.force.should be_false
    end

    it "reads --local with and without a path" do
      Update.parse(["--local"]).local_path.should be_nil
      options = Update.parse(["--local", "~/src/conduit"])
      options.local.should be_true
      options.local_path.should eq("~/src/conduit")
    end

    it "strips a leading v from --version" do
      Update.parse(["--version", "v0.1.0"]).version.should eq("0.1.0")
      Update.parse(["--version=0.2.3"]).version.should eq("0.2.3")
    end

    it "refuses a --version that is not X.Y.Z, or is missing" do
      expect_raises(Update::UsageError, /--version needs a version like 0\.1\.0, got "latest"/) do
        Update.parse(["--version", "latest"])
      end
      expect_raises(Update::UsageError, /--version needs a version/) { Update.parse(["--version"]) }
    end

    it "refuses --local together with --version" do
      expect_raises(Update::UsageError, /cannot be combined/) do
        Update.parse(["--local", "--version", "0.1.0"])
      end
    end

    it "refuses a path without --local, two paths, and an unknown option" do
      expect_raises(Update::UsageError, /goes with --local/) { Update.parse(["../conduit"]) }
      expect_raises(Update::UsageError, /at most one checkout path/) { Update.parse(["--local", "a", "b"]) }
      expect_raises(Update::UsageError, /unknown option --everything/) { Update.parse(["--everything"]) }
    end
  end

  describe ".install_args" do
    it "spells options the way install.sh reads them" do
      options = Update.parse(["--version", "0.1.0", "--preview", "--force"])
      Update.install_args(options).should eq(["--version", "0.1.0", "--preview", "--force"])
      Update.install_args(Update.parse([] of String)).should be_empty
    end
  end

  describe ".resolve_repo" do
    it "finds the root of a Conduit checkout from a subdirectory" do
      SpecHelper.sandbox do |sandbox|
        root = SpecHelper.checkout(sandbox)
        Update.resolve_repo(nil, (root / "tools").to_s).should eq(root)
      end
    end

    it "accepts a path relative to the working directory" do
      SpecHelper.sandbox do |sandbox|
        root = SpecHelper.checkout(sandbox)
        Update.resolve_repo("checkout", sandbox.root.to_s).should eq(root)
      end
    end

    it "refuses a repository with a bin/package and install.sh that is not Conduit" do
      SpecHelper.sandbox do |sandbox|
        root = SpecHelper.checkout(sandbox, conduit: false)
        Update.resolve_repo(nil, root.to_s).should be_nil
      end
    end

    it "refuses a directory outside any git repository, and one that does not exist" do
      SpecHelper.sandbox do |sandbox|
        Update.resolve_repo(nil, sandbox.root.to_s).should be_nil
        Update.resolve_repo("missing", sandbox.root.to_s).should be_nil
      end
    end
  end
end

describe "ConduitVPN::CLI.exit_code_for" do
  it "passes an exit code on, and reports a signal as 128 + the signal" do
    exited = Process.run("sh", ["-c", "exit 7"])
    ConduitVPN::CLI.exit_code_for(exited).should eq(7)
    signalled = Process.run("sh", ["-c", "kill -TERM $$"])
    ConduitVPN::CLI.exit_code_for(signalled).should eq(128 + Signal::TERM.value)
    ConduitVPN::CLI.describe_exit(signalled).should eq("signal TERM")
  end
end

describe "ConduitVPN::VERSION" do
  it "is the repository's VERSION, which shard.yml repeats" do
    root = Path.new(File.expand_path("../../../..", __DIR__))
    version = File.read(root / "VERSION").strip
    ConduitVPN::VERSION.should eq(version)
    shard = File.read_lines(root / "tools" / "conduit-vpn" / "shard.yml")
    shard.find(&.starts_with?("version: ")).should eq("version: #{version}")
  end
end
