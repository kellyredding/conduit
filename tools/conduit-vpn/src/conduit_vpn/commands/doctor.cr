module ConduitVPN
  module Commands
    # Answers "is this machine set up correctly" as a list of independent
    # checks rather than by failing on the first problem, because the answer
    # is usually more than one thing and a person fixing them wants the whole
    # list.
    #
    # Reports counts, never profile names. Diagnostic output is the most likely
    # thing to be pasted somewhere public.
    module Doctor
      extend self

      enum Level
        Pass
        Warn
        Fail

        def marker : String
          case self
          in .pass? then "ok  "
          in .warn? then "warn"
          in .fail? then "FAIL"
          end
        end
      end

      record Check, level : Level, name : String, detail : String

      def run(argv : Array(String)) : Int32
        if argv.includes?("--explain")
          STDOUT.puts Network.synthesis_explanation
          return CLI::OK
        end

        checks = [] of Check

        binary = ::ConduitVPN::Config.client_path
        home = ::ConduitVPN::Config.client_home
        client = Client.new(binary, home)

        # Only these two gate the rest: without a usable binary and a usable
        # home there is nothing to ask. Everything else reports independently,
        # and a warning from any of them must not silence the checks below —
        # which is exactly what gating on "every check passed" did.
        preconditions = [check_binary(client, binary), check_home(client, home)]
        checks.concat(preconditions)
        checks << check_address_synthesis
        checks << check_last_teardown

        if preconditions.all?(&.level.pass?)
          responds = check_responds(client)
          checks << responds
          checks << check_profiles(client) if responds.level.pass?
        end

        checks.concat(install_checks)

        width = checks.map(&.name.size).max
        checks.each do |result|
          STDOUT.puts "#{result.level.marker}  " \
                      "#{result.name.ljust(width)}  #{result.detail}"
        end

        checks.any?(&.level.fail?) ? CLI::FAILURE : CLI::OK
      end

      # Reported whether or not it is a problem, so this command's output has
      # the same shape everywhere. A check that appears only when it fails is
      # a check nobody knows exists until the day it does.
      private def check_address_synthesis : Check
        if Network.synthesizing_addresses?
          Check.new(
            Level::Warn,
            "addressing",
            "#{Network.summary} — connections will fail here; " \
            "run `conduit-vpn doctor --explain` for why",
          )
        else
          Check.new(Level::Pass, "addressing", Network.summary)
        end
      end

      # A teardown older than this is history rather than a diagnosis. Naming
      # it every run would train a reader to skip the line, which costs the
      # day it actually matters.
      TEARDOWN_RECENT = 1.hour

      # Why the last session ended, when the client ended it for a reason.
      #
      # This is the only check that reports something the client did rather
      # than something about this machine's setup, and it earns the place: a
      # tunnel that dies seconds after connecting looks like a broken setup,
      # and this is the line that says it is not one.
      #
      # No profile name, per the note at the top of this file.
      private def check_last_teardown : Check
        reading = DaemonTeardown.latest

        unless reading
          return Check.new(Level::Pass, "last teardown", "none recorded")
        end

        age = Time.utc - reading.at
        if age > TEARDOWN_RECENT
          return Check.new(Level::Pass, "last teardown", "none in the last hour")
        end

        detail = "#{reading.cause.summary}, #{humanize(age)} ago"
        detail += " — a new sign-in is needed" if reading.needs_sign_in
        Check.new(Level::Warn, "last teardown", detail)
      end

      private def humanize(span : Time::Span) : String
        minutes = span.total_minutes.round.to_i
        return "less than a minute" if minutes < 1
        minutes == 1 ? "1 minute" : "#{minutes} minutes"
      end

      LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Versions/" \
                   "Current/Frameworks/LaunchServices.framework/Versions/Current/" \
                   "Support/lsregister"

      # Overridable for specs only, so they never read ~/Applications or ask
      # the real Launch Services.
      def installed_app : Path
        dir = ENV["CONDUIT_APPLICATIONS_DIR"]?
        (dir && !dir.empty? ? Path.new(dir) : Path.home / "Applications") / "Conduit.app"
      end

      def lsregister : String
        ENV["CONDUIT_LSREGISTER"]?.try { |path| path unless path.empty? } || LSREGISTER
      end

      # Checked against the manifest install.sh copied out of the archive it
      # installed. No record is a warning: a source install has none.
      private def install_checks : Array(Check)
        path = Paths.installed_manifest
        manifest = read_manifest(path)
        unless manifest
          problem = ::File.exists?(path) ? "unreadable install record at" : "no install record at"
          return [Check.new(Level::Warn, "install",
            "#{problem} #{display(path)}; `conduit-vpn update` installs a release and writes one")]
        end

        checks = [Check.new(Level::Pass, "install", describe_install(manifest))]
        checks.concat(installed_app_checks(manifest))
        checks << installed_cli_check(manifest)
        checks.concat(registration_checks)
        checks
      end

      private def installed_app_checks(manifest : JSON::Any) : Array(Check)
        app = installed_app
        if ::File.symlink?(app)
          target = ::File.realpath(app) rescue "nothing"
          return [Check.new(Level::Fail, "installed app",
            "#{display(app)} is a link to #{display(target)}, not an installed copy; `conduit-vpn update` installs one")]
        end
        unless Dir.exists?(app)
          return [Check.new(Level::Fail, "installed app", "#{display(app)} is missing; `conduit-vpn update` installs it")]
        end

        checks = [] of Check
        version = plist_value(app, "CFBundleShortVersionString")
        commit = plist_value(app, "ConduitBuildCommit")
        recorded = manifest["commit"]?.try(&.as_s?)
        if commit.nil?
          checks << Check.new(Level::Fail, "installed app",
            "Conduit.app carries no build commit, so install.sh did not install it; `conduit-vpn update` replaces it")
        elsif recorded && commit != recorded
          checks << Check.new(Level::Fail, "installed app",
            "Conduit.app is from #{commit}, the install record from #{recorded}; `conduit-vpn update` reinstalls both")
        else
          checks << Check.new(Level::Pass, "installed app", "Conduit.app #{version || "unknown version"} (#{commit})")
        end

        signer = signing_authority(app)
        expected = manifest["signer"]?.try(&.as_s?)
        if signer.nil?
          checks << Check.new(Level::Fail, "app signer", "Conduit.app is ad hoc or unsigned, not the release identity")
        elsif expected && signer != expected
          checks << Check.new(Level::Fail, "app signer", "Conduit.app is signed by #{signer}, the install record says #{expected}")
        else
          checks << Check.new(Level::Pass, "app signer", "Conduit.app signed by #{signer}")
        end
        checks
      end

      private def installed_cli_check(manifest : JSON::Any) : Check
        binary = Paths.installed_cli
        expected = manifest["conduit_vpn_sha256"]?.try(&.as_s?)
        sha256 = ::File.file?(binary) ? sha256_of(binary) : nil
        if sha256.nil?
          Check.new(Level::Fail, "installed cli", "#{display(binary)} is missing; `conduit-vpn update` installs it")
        elsif expected.nil?
          Check.new(Level::Warn, "installed cli", "the install record has no checksum to compare #{display(binary)} with")
        elsif sha256 == expected
          Check.new(Level::Pass, "installed cli", "#{display(binary)} is the recorded build")
        else
          Check.new(Level::Fail, "installed cli",
            "#{display(binary)} is not the build the install record names; `conduit-vpn update` reinstalls it")
        end
      end

      # Conduit registers no URL scheme, so a stray copy only confuses
      # Spotlight and `open -a`: a warning, not a failure.
      private def registration_checks : Array(Check)
        output = IO::Memory.new
        status = Process.run(lsregister, ["-dump"], output: output, error: Process::Redirect::Close)
        unless status.success?
          return [Check.new(Level::Warn, "registration",
            "could not ask Launch Services (lsregister #{CLI.describe_exit(status)})")]
        end
        paths = output.to_s.lines.compact_map do |line|
          line.match(/^path:\s+(.*\/Conduit\.app) \(0x[0-9a-f]+\)$/).try(&.[1])
        end.uniq

        app = installed_app.to_s
        checks = [] of Check
        if paths.includes?(app)
          checks << Check.new(Level::Pass, "registration", "Launch Services knows #{display(app)}")
        else
          checks << Check.new(Level::Warn, "registration", "Launch Services does not know #{display(app)}; `conduit-vpn update` registers it")
        end
        paths.reject(app).each do |other|
          checks << Check.new(Level::Warn, "registration", "another Conduit.app is registered: #{display(other)}")
        end
        checks
      rescue error : ::File::Error
        [Check.new(Level::Warn, "registration", "could not ask Launch Services: #{error.message}")]
      end

      # Not Digest::SHA256: it links Homebrew's OpenSSL, which bin/package
      # refuses to ship.
      private def sha256_of(path : Path) : String?
        output = IO::Memory.new
        status = Process.run("/usr/bin/shasum", ["-a", "256", path.to_s],
          output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s.split.first? : nil
      end

      private def plist_value(app : Path, key : String) : String?
        output = IO::Memory.new
        status = Process.run("/usr/libexec/PlistBuddy", ["-c", "Print :#{key}", (app / "Contents" / "Info.plist").to_s],
          output: output, error: Process::Redirect::Close)
        status.success? ? output.to_s.strip : nil
      end

      private def signing_authority(app : Path) : String?
        output = IO::Memory.new
        Process.run("codesign", ["-dv", "--verbose=2", app.to_s], output: output, error: output)
        output.to_s.each_line.find(&.starts_with?("Authority=")).try(&.lchop("Authority="))
      end

      private def read_manifest(path : Path) : JSON::Any?
        return nil unless ::File.file?(path)
        manifest = JSON.parse(::File.read(path))
        manifest.as_h? ? manifest : nil
      rescue JSON::ParseException | ::File::Error
        nil
      end

      private def describe_install(manifest : JSON::Any) : String
        field = ->(name : String) { manifest[name]?.try(&.as_s?) }
        build = [field.call("commit") || "unknown commit"]
        build << "uncommitted changes" if manifest["dirty"]?.try(&.as_bool?)
        detail = "Conduit #{field.call("version") || "unknown"} (#{build.join(", ")})"
        field.call("built_at").try { |built| detail += ", built #{built}" }
        signer = field.call("signer")
        detail += signer ? ", signed by #{signer}" : ", signer not recorded"
        detail
      end

      # The home directory as ~, so output pasted elsewhere carries no username.
      private def display(path : Path | String) : String
        text = path.to_s
        home = Path.home.to_s
        text.starts_with?("#{home}/") ? "~#{text.lchop(home)}" : text
      end

      private def check_binary(client : Client, binary : Path) : Check
        client.ensure_installed!
        Check.new(Level::Pass, "client binary", binary.to_s)
      rescue error : Client::NotInstalled
        Check.new(Level::Fail, "client binary", "not found at #{binary}")
      end

      private def check_home(client : Client, home : Path) : Check
        client.ensure_client_home!
        Check.new(Level::Pass, "client home", home.to_s)
      rescue error : Client::HomeNotCanonical
        Check.new(
          Level::Fail,
          "client home",
          "#{home} is reached through a symlink; the client would abort",
        )
      rescue error : ::File::Error
        Check.new(Level::Fail, "client home", "cannot create #{home}")
      end

      private def check_responds(client : Client) : Check
        client.capture(["list-profiles"])
        Check.new(Level::Pass, "client responds", "answered a profile listing")
      rescue error : Client::CommandFailed
        Check.new(
          Level::Fail,
          "client responds",
          error.message || "the client returned an error",
        )
      end

      private def check_profiles(client : Client) : Check
        profiles = Models.profiles(client.capture(["list-profiles"]))

        if profiles.empty?
          # Not a failure. Conduit does not provision profiles, so an empty
          # list is a legitimate state that simply leaves nothing to connect.
          Check.new(
            Level::Warn,
            "profiles",
            "none installed — nothing to connect to",
          )
        else
          Check.new(Level::Pass, "profiles", "#{profiles.size} installed")
        end
      rescue error : JSON::Error
        Check.new(
          Level::Fail,
          "profiles",
          "the client's response could not be read",
        )
      end
    end
  end
end
