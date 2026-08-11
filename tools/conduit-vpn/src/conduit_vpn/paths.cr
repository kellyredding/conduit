module ConduitVPN
  # Centralized path resolution. Nothing else builds these paths ad-hoc.
  # Every value is env-overridable so specs isolate to temporary directories
  # instead of touching a real installation.
  #
  # MIRROR: ConduitApp/ConduitApp/Models/Paths.swift
  #
  # `client_home` deliberately does NOT live here. It is a user-facing
  # setting rather than a fixed layout element — a machine whose home
  # directory sits under file sync has to be able to move it — so it is
  # resolved through Config with the rest of the settings.
  module Paths
    extend self

    def root : Path
      Path.new(ENV.fetch("CONDUIT_ROOT", (Path.home / ".conduit").to_s))
    end

    def bin_dir : Path
      root / "bin"
    end

    def log_dir : Path
      root / "logs"
    end

    def config_file : Path
      Path.new(ENV.fetch("CONDUIT_CONFIG", (root / "config.json").to_s))
    end

    # Documents every setting. Written at install time and never read back —
    # the resolver treats an absent config file as "everything is default",
    # so a file that merely restated the defaults would shadow later
    # improvements to them.
    def example_config_file : Path
      root / "config.example.json"
    end
  end
end
