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
  # File-backed and flag-backed overrides are not consulted yet — only the
  # environment and the defaults are. The order above is the contract they
  # slot into, and `Source` already names every layer so that adding one
  # does not change the shape of what callers receive.
  #
  # MIRROR: ConduitApp/ConduitApp/Models/Config.swift
  module Config
    extend self

    # `default` is a proc rather than a string because some defaults are
    # derived from other resolved values (the root directory, itself
    # env-overridable) and so cannot be known at compile time.
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

      def to_s(io : IO) : Nil
        io << super.downcase
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
        description: "Directory supplied to the AWS VPN Client as HOME. Its " \
                     ".config must be a real directory: the client derives " \
                     "its log path from HOME and refuses a path containing " \
                     "symlinks.",
        default: -> { (Paths.root / "client-home").to_s },
      ),
    ]

    class UnknownKey < Exception
      def initialize(name : String)
        super("unknown setting: #{name}")
      end
    end

    def keys : Array(Key)
      KEYS
    end

    def key?(name : String) : Key?
      KEYS.find { |k| k.name == name }
    end

    def key!(name : String) : Key
      key?(name) || raise UnknownKey.new(name)
    end

    def resolve(name : String) : Resolved
      key = key!(name)

      if value = ENV[key.env]?
        return Resolved.new(key: key, value: value, source: Source::Env)
      end

      Resolved.new(key: key, value: key.default.call, source: Source::Default)
    end

    def effective : Array(Resolved)
      KEYS.map { |key| resolve(key.name) }
    end

    def get(name : String) : String
      resolve(name).value
    end

    # Path-valued settings are expanded here rather than at each call site,
    # so a value typed with a leading ~ behaves the same whether it arrived
    # from a shell (already expanded) or from a config file (not).
    def path(name : String) : Path
      Path.new(get(name)).expand(home: true)
    end

    def client_path : Path
      path("client-path")
    end

    def client_home : Path
      path("client-home")
    end
  end
end
