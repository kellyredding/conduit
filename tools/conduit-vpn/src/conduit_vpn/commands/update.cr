require "file_utils"

module ConduitVPN
  module Commands
    module Update
      extend self

      INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/kellyredding/conduit/main/install.sh"
      ARCHIVE            = "conduit-darwin-arm64.tar.gz"

      HELP = <<-TEXT
        conduit-vpn update — install the latest release, or a Conduit checkout

        Usage:
          conduit-vpn update                   Install the latest release
          conduit-vpn update --version X.Y.Z   Install that release
          conduit-vpn update --local [PATH]    Package and install a Conduit checkout
                                               (PATH, else the repository you are in),
                                               uncommitted changes included

        Options:
          --preview   Show what would change, and change nothing
          --force     Reinstall a release even when it is already installed

        Replaces ~/.conduit/bin/conduit-vpn and ~/Applications/Conduit.app, and
        rewrites ~/.conduit/config.example.json. Settings are left alone. A running
        Conduit keeps the old build until you restart it; update never restarts it.

        Releases install through #{INSTALL_SCRIPT_URL}
        --local runs the checkout's bin/package, which signs with the "Conduit
        Release Signing" identity from 1Password and may ask you to approve it.
        Exits with the installer's or the packager's exit code when either fails,
        and 2 on a usage error.
        TEXT

      class UsageError < Error
      end

      record Options,
        local : Bool = false,
        local_path : String? = nil,
        version : String? = nil,
        preview : Bool = false,
        force : Bool = false

      def run(argv : Array(String)) : Int32
        return CLI.print_help(HELP) if CLI.help_requested?(argv)

        options = begin
          parse(argv)
        rescue error : UsageError
          STDERR.puts "conduit-vpn: #{error.message}"
          return CLI::USAGE
        end

        CLI.guard { options.local ? run_local(options) : run_release(options) }
      end

      def parse(argv : Array(String)) : Options
        local = false
        preview = false
        force = false
        raw_version : String? = nil
        positionals = [] of String

        index = 0
        while index < argv.size
          argument = argv[index]
          case argument
          when "--local"   then local = true
          when "--preview" then preview = true
          when "--force"   then force = true
          when "--version"
            index += 1
            raw_version = argv[index]? || raise UsageError.new("--version needs a version like 0.1.0")
          else
            if argument.starts_with?("--version=")
              raw_version = argument.split('=', 2)[1]
            elsif argument.starts_with?('-')
              raise UsageError.new("update: unknown option #{argument}")
            else
              positionals << argument
            end
          end
          index += 1
        end

        if positionals.size > 1
          raise UsageError.new("update takes at most one checkout path, got #{positionals.size}")
        end
        path = positionals.first?
        if path && !local
          raise UsageError.new("unexpected argument #{path.inspect}; a checkout path goes with --local")
        end

        version = raw_version.try do |raw|
          bare = raw.lchop('v')
          unless bare.matches?(/\A\d+\.\d+\.\d+\z/)
            raise UsageError.new("--version needs a version like 0.1.0, got #{raw.inspect}")
          end
          bare
        end
        if local && version
          raise UsageError.new("--local packages a checkout; it cannot be combined with --version")
        end

        Options.new(local: local, local_path: path, version: version, preview: preview, force: force)
      end

      # Flags for install.sh, in its own spelling.
      def install_args(options : Options) : Array(String)
        args = [] of String
        options.version.try { |version| args.concat(["--version", version]) }
        args << "--preview" if options.preview
        args << "--force" if options.force
        args
      end

      # The checkout to package: PATH, else the git root of the working
      # directory. Nil when that is not a Conduit checkout.
      def resolve_repo(path : String?, cwd : String = Dir.current) : Path?
        start = path ? File.expand_path(path, cwd, home: true) : cwd
        return nil unless Dir.exists?(start)

        output = IO::Memory.new
        status = Process.run("git", ["-C", start, "rev-parse", "--show-toplevel"],
          output: output, error: Process::Redirect::Close)
        return nil unless status.success?

        root = Path.new(output.to_s.strip)
        conduit_repo?(root) ? root : nil
      rescue File::Error
        nil
      end

      # Sibling projects' checkouts have a bin/package and an install.sh too,
      # so those alone would let --local install another project's archive.
      def conduit_repo?(root : Path) : Bool
        File.file?(root / "bin" / "package") && File.file?(root / "install.sh") &&
          File.file?(root / "ConduitApp" / "project.yml")
      end

      # The script is fetched before bash runs it: piped straight into bash, a
      # failed download is an empty script, which bash runs and exits 0.
      private def run_release(options : Options) : Int32
        script = IO::Memory.new
        fetched = execute("curl", ["-fsSL", INSTALL_SCRIPT_URL], output: script)
        unless fetched.success?
          raise Error.new("could not download the installer from #{INSTALL_SCRIPT_URL} (#{CLI.describe_exit(fetched)})")
        end
        script.rewind
        CLI.exit_code_for(execute("bash", ["-s", "--"] + install_args(options), input: script))
      end

      private def run_local(options : Options) : Int32
        repo = resolve_repo(options.local_path)
        unless repo
          where = options.local_path || Dir.current
          raise Error.new("#{where} is not inside a Conduit checkout (no bin/package, install.sh and ConduitApp/project.yml)")
        end

        out_dir = Path.new(File.tempname("conduit-local-", nil))
        begin
          packaged = execute((repo / "bin" / "package").to_s, ["--local", "--out", out_dir.to_s])
          return CLI.exit_code_for(packaged) unless packaged.success?

          archive = out_dir / ARCHIVE
          raise Error.new("bin/package wrote no #{ARCHIVE} in #{out_dir}") unless File.file?(archive)
          installer = ["--from", archive.to_s] + install_args(options)
          CLI.exit_code_for(execute("bash", [(repo / "install.sh").to_s] + installer))
        ensure
          FileUtils.rm_rf(out_dir.to_s)
        end
      end

      private def execute(command : String, args : Array(String),
                          input : Process::Stdio = Process::Redirect::Inherit,
                          output : Process::Stdio = Process::Redirect::Inherit) : Process::Status
        Process.run(command, args, input: input, output: output, error: Process::Redirect::Inherit)
      rescue error : File::Error
        raise Error.new("could not run #{command}: #{error.message}")
      end
    end
  end
end
