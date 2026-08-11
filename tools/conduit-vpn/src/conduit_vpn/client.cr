module ConduitVPN
  # Runs the AWS VPN Client's command-line binary with a corrected HOME.
  #
  # The client derives its log directory from HOME as
  # "$HOME/.config/AWSVPNClient/logs" and refuses to start unless that path
  # is free of symlinks anywhere along it. On a machine whose ~/.config is a
  # symlink — a common dotfile-syncing arrangement — it aborts before doing
  # any work. Supplying a HOME whose .config is a real directory satisfies
  # the check.
  #
  # Nothing else in the client reads HOME: profiles live under
  # /Library/Application Support and the daemon socket is system-wide, so
  # the override changes only where the client writes its own logs.
  class Client
    class NotInstalled < ConduitVPN::Error
      def initialize(binary : Path)
        super(<<-MSG)
        AWS VPN Client command-line binary not found at:
          #{binary}
        It ships with client version 6.0 and later. Set a different location
        with: conduit-vpn config set client-path <path>
        MSG
      end
    end

    class HomeNotCanonical < ConduitVPN::Error
      def initialize(requested : Path, resolved : String)
        super(<<-MSG)
        #{requested} must be a real directory, not a symlink.
        It currently resolves to: #{resolved.presence || "<unresolvable>"}
        The AWS VPN Client rejects a log path containing symlinks and would
        abort. Set a different location with:
          conduit-vpn config set client-home <path>
        MSG
      end
    end

    # A non-zero exit from the client. Errors arrive as a JSON envelope on
    # stdout rather than on stderr, so the message is recovered from the
    # captured output.
    class CommandFailed < ConduitVPN::Error
      getter exit_code : Int32
      getter payload : String

      def initialize(@exit_code : Int32, @payload : String)
        super(Models.error_message(@payload) || "exited #{@exit_code}")
      end
    end

    getter binary : Path
    getter client_home : Path

    def initialize(@binary : Path, @client_home : Path)
    end

    def self.from_config : Client
      new(Config.client_path, Config.client_home)
    end

    # Forward argv to the client with this process's streams attached, and
    # return its exit code. Nothing is buffered, parsed, or rewritten, so a
    # forwarded command is indistinguishable from invoking the client
    # directly — which is the entire promise of passthrough.
    def exec(args : Array(String)) : Int32
      prepare!

      status = Process.run(
        @binary.to_s,
        args,
        env: {"HOME" => @client_home.to_s},
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
      status.exit_code
    end

    # Capture stdout for Conduit's own use. Raises CommandFailed on a
    # non-zero exit so callers handle failure explicitly rather than
    # parsing an error envelope as if it were data.
    def capture(args : Array(String)) : String
      prepare!

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        @binary.to_s,
        args,
        env: {"HOME" => @client_home.to_s},
        output: stdout,
        error: stderr,
      )

      return stdout.to_s if status.success?
      raise CommandFailed.new(
        status.exit_code,
        stdout.to_s.presence || stderr.to_s,
      )
    end

    private def prepare! : Nil
      ensure_installed!
      ensure_client_home!
    end

    # Public so that `doctor` can report on each precondition separately
    # rather than inferring both from one failed command.
    def ensure_installed! : Nil
      return if File::Info.executable?(@binary.to_s)
      raise NotInstalled.new(@binary)
    end

    # Checked on every invocation rather than once at install time. The
    # directory can be removed, or acquire a synced parent, at any point
    # after installation — and the cost of being wrong is an opaque crash
    # inside the client instead of the message above.
    def ensure_client_home! : Nil
      config_dir = @client_home / ".config"
      Dir.mkdir_p(config_dir.to_s)

      resolved = begin
        File.realpath(config_dir.to_s)
      rescue
        ""
      end

      return if resolved == config_dir.to_s
      raise HomeNotCanonical.new(config_dir, resolved)
    end
  end
end
