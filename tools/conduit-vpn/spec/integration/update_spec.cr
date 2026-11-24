require "../spec_helper"

# Stand-ins for the network: `curl` prints its arguments to stderr and
# answers with the given installer script, or exits 22 as `curl -f` does on
# an HTTP error.
private def fake_curl(sandbox : SpecHelper::Sandbox, installer : String?) : Hash(String, String?)
  bin = sandbox.root / "fakebin"
  body = if installer
           "#!/bin/sh\necho \"curl $*\" >&2\ncat <<'EOF'\n#{installer}\nEOF\n"
         else
           "#!/bin/sh\necho \"curl: (22) The requested URL returned error: 404\" >&2\nexit 22\n"
         end
  SpecHelper.write_executable(bin / "curl", body)
  {"PATH" => "#{bin}:/usr/bin:/bin"} of String => String?
end

private PACKAGE = <<-SH
  #!/bin/sh
  echo "package $*"
  while [ $# -gt 0 ]; do
    case "$1" in --out) out="$2"; shift ;; esac
    shift
  done
  mkdir -p "$out"
  echo archive > "$out/conduit-darwin-arm64.tar.gz"

  SH

private INSTALL = <<-SH
  #!/bin/sh
  echo "install.sh $*"
  [ -f "$2" ] && echo "archive present"
  exit 0

  SH

describe "conduit-vpn update" do
  it "runs the installer from main with install.sh's own flags" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "installer $*"\necho "root $CONDUIT_ROOT"))
      result = SpecHelper.run(sandbox, ["update", "--version", "v0.2.0", "--preview", "--force"], env)
      result.exit_code.should eq(0)
      result.stderr.should contain("curl -fsSL #{ConduitVPN::Commands::Update::INSTALL_SCRIPT_URL}\n")
      result.stdout.should contain("installer --version 0.2.0 --preview --force\n")
      result.stdout.should contain("root #{sandbox.root}\n")
    end
  end

  it "installs the latest release when given no version" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "installer [$*]"))
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(0)
      result.stdout.should eq("installer []\n")
    end
  end

  it "exits with the installer's exit code" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, %(echo "no release" >&2\nexit 7))
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(7)
      result.stderr.should contain("no release")
    end
  end

  it "fails, running nothing, when the installer does not download" do
    SpecHelper.sandbox do |sandbox|
      env = fake_curl(sandbox, nil)
      result = SpecHelper.run(sandbox, ["update"], env)
      result.exit_code.should eq(1)
      result.stdout.should be_empty
      result.stderr.should contain("conduit-vpn: could not download the installer from " \
                                   "#{ConduitVPN::Commands::Update::INSTALL_SCRIPT_URL} (exit 22)")
    end
  end

  it "--local packages the checkout it is run from and installs the archive with its install.sh" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: INSTALL)
      result = SpecHelper.run(sandbox, ["update", "--local", "--preview"], chdir: (root / "tools").to_s)
      result.exit_code.should eq(0)

      out_dir = result.stdout[/^package --local --out (\S+)$/m, 1]
      archive = "#{out_dir}/conduit-darwin-arm64.tar.gz"
      result.stdout.should contain("install.sh --from #{archive} --preview\narchive present\n")
      Dir.exists?(out_dir).should be_false
    end
  end

  it "--local PATH packages that checkout" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: INSTALL)
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(0)
      result.stdout.should contain("archive present\n")
    end
  end

  it "--local refuses a directory that is not a Conduit checkout" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: PACKAGE, install: INSTALL, conduit: false)
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(1)
      result.stdout.should be_empty
      result.stderr.should contain("#{root} is not inside a Conduit checkout")
    end
  end

  it "--local stops with the packager's exit code, or 128 + its signal, before installing" do
    SpecHelper.sandbox do |sandbox|
      {"exit 3" => 3, "kill -TERM $$" => 128 + Signal::TERM.value}.each do |ending, code|
        root = SpecHelper.checkout(sandbox, package: "#!/bin/sh\n#{ending}\n", install: INSTALL)
        result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
        result.exit_code.should eq(code)
        result.stdout.should_not contain("install.sh")
      end
    end
  end

  it "--local fails when the packager writes no archive" do
    SpecHelper.sandbox do |sandbox|
      root = SpecHelper.checkout(sandbox, package: "#!/bin/sh\nexit 0\n", install: INSTALL)
      result = SpecHelper.run(sandbox, ["update", "--local", root.to_s])
      result.exit_code.should eq(1)
      result.stderr.should contain("bin/package wrote no conduit-darwin-arm64.tar.gz")
      result.stdout.should_not contain("install.sh")
    end
  end

  it "exits 2 on a usage error, and documents its flags" do
    SpecHelper.sandbox do |sandbox|
      refused = SpecHelper.run(sandbox, ["update", "--local", "--version", "0.1.0"])
      refused.exit_code.should eq(2)
      refused.stderr.should contain("conduit-vpn: --local packages a checkout; it cannot be combined with --version")
      SpecHelper.run(sandbox, ["update", "--json"]).exit_code.should eq(2)

      help = SpecHelper.run(sandbox, ["update", "--help"])
      help.exit_code.should eq(0)
      help.stdout.should contain("conduit-vpn update --local [PATH]")
      help.stdout.should contain("keeps the old build until you restart it")
    end
  end

  it "is listed in the usage" do
    SpecHelper.sandbox do |sandbox|
      SpecHelper.run(sandbox, ["--help"]).stdout.should match(/^  update\s+Install the latest release/m)
    end
  end
end
