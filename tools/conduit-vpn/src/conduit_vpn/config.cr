require "json"

module ConduitVPN
  # Settings resolution.
  #
  #   flag  >  environment variable  >  config file  >  compiled default
  #
  # The config file records only what differs from a default. It is never
  # written with the defaults themselves: a file that restated them would
  # freeze the values of its install date, so improving a default in code
  # would silently have no effect on any machine that already ran the
  # installer. An absent, empty, or partial file is the normal case.
  #
  # MIRROR: ConduitApp/ConduitApp/Models/Config.swift
  module Config
    extend self

    # `default` is a proc rather than a string because some defaults derive
    # from other resolved values — the root directory, itself overridable —
    # and so cannot be known at compile time.
    record Key,
      name : String,
      env : String,
      description : String,
      default : Proc(String)

    enum Source
      Default
      File
      Env
      Flag

      def label : String
        to_s.downcase
      end
    end

    record Resolved,
      key : Key,
      value : String,
      source : Source

    KEYS = [
      Key.new(
        name: "client-path",
        env: "CONDUIT_CLIENT_PATH",
        description: "Path to the AWS VPN Client command-line binary.",
        default: -> {
          "/Applications/AWS VPN Client/AWS VPN Client.app" \
          "/Contents/MacOS/aws-vpn-client"
        },
      ),
      Key.new(
        name: "client-home",
        env: "CONDUIT_CLIENT_HOME",
        description: "Directory supplied to the client as HOME. Its .config " \
                     "must be a real directory: the client derives its log " \
                     "path from HOME and rejects one containing symlinks.",
        default: -> { (Paths.root / "client-home").to_s },
      ),
      Key.new(
        name: "sensitive-profile-pattern",
        env: "CONDUIT_SENSITIVE_PATTERN",
        description: "Profiles whose name matches this expression need " \
                     "explicit confirmation before connecting. Empty " \
                     "disables the check entirely.",
        default: -> { "(?i)prod" },
      ),
      Key.new(
        name: "poll-interval-active",
        env: "CONDUIT_POLL_ACTIVE",
        description: "Seconds between status checks while an attempt is in " \
                     "flight or the menu is open.",
        default: -> { "2" },
      ),
      Key.new(
        name: "poll-interval-idle",
        env: "CONDUIT_POLL_IDLE",
        description: "Seconds between connection checks at rest, with the " \
                     "menu closed. Used by the menu bar application, which " \
                     "polls continuously; only the connection listing is " \
                     "re-read at this rate.",
        default: -> { "2" },
      ),
      Key.new(
        name: "connect-timeout",
        env: "CONDUIT_CONNECT_TIMEOUT",
        description: "Seconds to keep watching a connection attempt before " \
                     "giving up. Generous by default: sign-in happens in a " \
                     "browser and may be waiting on a person.",
        default: -> { "120" },
      ),
      Key.new(
        name: "identity-hint-after",
        env: "CONDUIT_IDENTITY_HINT_AFTER",
        description: "Seconds to wait in the sign-in state before saying " \
                     "out loud that a browser is waiting.",
        default: -> { "15" },
      ),
      Key.new(
        name: "connect-grace-polls",
        env: "CONDUIT_CONNECT_GRACE_POLLS",
        description: "Consecutive not-connected readings tolerated straight " \
                     "after issuing a connect, before calling it a failure. " \
                     "The client takes a moment to register an attempt.",
        default: -> { "3" },
      ),
    ]

    class UnknownKey < ConduitVPN::Error
      def initialize(name : String)
        super("unknown setting: #{name}")
      end
    end

    class NotAnInteger < ConduitVPN::Error
      def initialize(name : String, value : String)
        super("setting #{name} must be a whole number, got: #{value.inspect}")
      end
    end

    @@overrides = {} of String => String

    # Applied by whichever command parsed the flag. Kept out of the key table
    # because most settings have no natural flag, and inventing one for each
    # would grow a global flag surface nobody asked for.
    def override(name : String, value : String) : Nil
      key!(name)
      @@overrides[name] = value
    end

    def clear_overrides : Nil
      @@overrides.clear
    end

    def keys : Array(Key)
      KEYS
    end

    def key?(name : String) : Key?
      KEYS.find { |key| key.name == name }
    end

    def key!(name : String) : Key
      key?(name) || raise UnknownKey.new(name)
    end

    def resolve(name : String, file : Hash(String, String)? = nil) : Resolved
      key = key!(name)

      if value = @@overrides[key.name]?
        return Resolved.new(key: key, value: value, source: Source::Flag)
      end

      if value = ENV[key.env]?
        return Resolved.new(key: key, value: value, source: Source::Env)
      end

      values = file || file_values
      if value = values[key.name]?
        return Resolved.new(key: key, value: value, source: Source::File)
      end

      Resolved.new(key: key, value: key.default.call, source: Source::Default)
    end

    # Reads the file once and shares it, rather than re-reading per key.
    def effective : Array(Resolved)
      values = file_values
      KEYS.map { |key| resolve(key.name, file: values) }
    end

    def get(name : String) : String
      resolve(name).value
    end

    def int(name : String) : Int32
      raw = get(name)
      raw.to_i? || raise NotAnInteger.new(name, raw)
    end

    def seconds(name : String) : Time::Span
      int(name).seconds
    end

    # Path-valued settings are expanded here rather than at each call site, so
    # a value typed with a leading tilde behaves the same whether it arrived
    # from a shell (already expanded) or from the config file (not).
    def path(name : String) : Path
      Path.new(get(name)).expand(home: true)
    end

    def client_path : Path
      path("client-path")
    end

    def client_home : Path
      path("client-home")
    end

    # --- File layer ---

    def file_values : Hash(String, String)
      path = Paths.config_file
      return {} of String => String unless ::File.exists?(path.to_s)

      parsed = JSON.parse(::File.read(path.to_s))
      object = parsed.as_h?
      unless object
        warn_about(path, "expected a JSON object")
        return {} of String => String
      end

      result = {} of String => String
      object.each do |name, value|
        next unless key?(name)
        if scalar = scalar_to_s(value)
          result[name] = scalar
        end
      end
      result
    rescue error : JSON::ParseException
      warn_about(Paths.config_file, error.message || "unparseable")
      {} of String => String
    end

    def set(name : String, value : String) : Nil
      key!(name)
      values = raw_file_object
      values[name] = JSON::Any.new(value)
      write(values)
    end

    def unset(name : String) : Nil
      key!(name)
      values = raw_file_object
      values.delete(name)
      write(values)
    end

    # Every key at its default, as valid JSON. Written at install time and
    # never read back — deliberately copy-and-edit safe, which is why it
    # carries no comments a parser would reject.
    def example_json : String
      object = {} of String => JSON::Any
      KEYS.each { |key| object[key.name] = JSON::Any.new(key.default.call) }
      JSON.build(indent: "  ") { |json| object.to_json(json) } + "\n"
    end

    private def raw_file_object : Hash(String, JSON::Any)
      path = Paths.config_file
      return {} of String => JSON::Any unless ::File.exists?(path.to_s)
      JSON.parse(::File.read(path.to_s)).as_h? || {} of String => JSON::Any
    rescue JSON::ParseException
      {} of String => JSON::Any
    end

    private def write(values : Hash(String, JSON::Any)) : Nil
      path = Paths.config_file
      Dir.mkdir_p(path.dirname)
      body = JSON.build(indent: "  ") { |json| values.to_json(json) }
      ::File.write(path.to_s, body + "\n")
    end

    private def scalar_to_s(value : JSON::Any) : String?
      case raw = value.raw
      when String         then raw
      when Int64, Float64 then raw.to_s
      when Bool           then raw.to_s
      else                     nil
      end
    end

    # A malformed file degrades to defaults rather than aborting: the command
    # the user actually asked for is usually still possible, and a settings
    # file is a poor reason to refuse to report connection status.
    private def warn_about(path : Path, reason : String) : Nil
      STDERR.puts "conduit-vpn: ignoring #{path} (#{reason})"
    end
  end
end
