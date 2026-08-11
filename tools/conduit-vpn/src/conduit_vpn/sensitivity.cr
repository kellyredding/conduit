module ConduitVPN
  # Which profiles need saying yes out loud.
  #
  # The rule used to live in prose, which meant it was enforced by whoever was
  # reading choosing to honor it. Enforcing it here makes it mechanical for
  # every caller — a person at a terminal, the menu bar application, and any
  # agent — without any of them having to know the rule exists.
  module Sensitivity
    extend self

    class Refused < ConduitVPN::Error
      def initialize(profile : String)
        super(
          "#{profile} matches the sensitive-profile pattern. " \
          "Re-run with --yes to confirm connecting to it."
        )
      end
    end

    class BadPattern < ConduitVPN::Error
      def initialize(pattern : String, reason : String)
        super(
          "sensitive-profile-pattern is not a valid expression: " \
          "#{pattern.inspect} (#{reason}). Fix it with: " \
          "conduit-vpn config set sensitive-profile-pattern <expression>"
        )
      end
    end

    # An empty pattern disables the check. Treating it as a regex instead
    # would match every profile, turning "I do not want this" into "guard
    # everything" — the opposite of what emptying a setting means.
    def pattern? : Regex?
      raw = Config.get("sensitive-profile-pattern")
      return nil if raw.empty?

      begin
        Regex.new(raw)
      rescue error : ArgumentError
        raise BadPattern.new(raw, error.message || "unparseable")
      end
    end

    def sensitive?(profile : String) : Bool
      return false unless expression = pattern?
      !!expression.match(profile)
    end

    def guard!(profile : String, confirmed : Bool) : Nil
      return unless sensitive?(profile)
      return if confirmed
      raise Refused.new(profile)
    end
  end
end
