module ConduitVPN
  # Why the client last ended a session, read from the daemon's own log.
  #
  # MIRRORS the parsing in ConduitApp/ConduitApp/Models/DaemonTeardown.swift,
  # with one deliberate difference: no profile name travels out of here. The
  # app puts the name on screen, where it already appears in every row. This
  # side feeds `doctor`, whose output is the most likely thing in the project
  # to be pasted somewhere public, so it carries a cause and an age and
  # nothing that identifies a deployment.
  #
  # The log itself is full of what this repository must never contain, so
  # what is taken from it is a cause and an instant — never a line of it.
  module DaemonTeardown
    extend self

    enum Cause
      LocalNetworkChanged
      SignInRequired
      ServerAddressRejected

      def summary : String
        case self
        in .local_network_changed?
          "a new local network appeared while a tunnel was up"
        in .sign_in_required?
          "a reconnect was asked to sign in again"
        in .server_address_rejected?
          "the address the tunnel came up on was rejected"
        end
      end
    end

    record Reading, at : Time, cause : Cause, needs_sign_in : Bool

    LOCAL_NETWORK    = "new LAN detected, stopping session"
    NEEDS_IDENTITY   = "old_state=Reconnecting new_state=WaitingForIdentity"
    ADDRESS_REJECTED = "ServerIpValidationFailed"

    # A local network change and the sign-in demand it provokes arrive within a
    # couple of seconds of each other. Generous beside that, and far short of
    # the gap between unrelated sessions.
    CONSEQUENCE_WINDOW = 120.seconds

    # Enough for a working day of sessions without reading a file that has been
    # growing since the client was installed.
    TAIL_BYTES = 512 * 1024

    # Bounded so a long file cannot make this proportional to the client's
    # whole history.
    MAX_LINES = 20_000

    def latest(dir : Path = Paths.daemon_log_dir) : Reading?
      file = newest_log(dir)
      return nil unless file
      text = tail(file)
      return nil unless text
      parse(text)
    end

    # Only the current file, never a rotation.
    #
    # The number in `aws_vpn_client_daemon_20260830.log` looks like a date and
    # is not one — it did not move across eight days of observed rotation, so
    # it tracks the installation. Building the name from today finds nothing.
    # Rotations end in a digit, which is what keeps them out.
    def newest_log(dir : Path) : Path?
      return nil unless Dir.exists?(dir.to_s)

      Dir.children(dir.to_s)
        .select { |name|
          name.starts_with?("aws_vpn_client_daemon") && name.ends_with?(".log")
        }
        .map { |name| dir / name }
        .max_by? { |path| File.info(path.to_s).modification_time }
    rescue File::Error
      nil
    end

    def tail(file : Path, bytes : Int32 = TAIL_BYTES) : String?
      size = File.size(file.to_s)
      start = size > bytes ? size - bytes : 0_i64

      text = File.open(file.to_s) do |io|
        io.seek(start)
        io.gets_to_end
      end

      return text if start.zero?

      # An offset chosen in bytes lands mid-line, so the first one is partial
      # and not worth parsing.
      index = text.index('\n')
      index ? text[(index + 1)..] : text
    rescue File::Error
      nil
    end

    # `AUTH_FAILED` is deliberately not a marker, and this is the whole
    # subtlety here. It is how a federated sign-in *begins*: the first connect
    # draws a challenge, the client reports AUTH_FAILED and a
    # DYNAMIC_CHALLENGE, a browser opens, and the retry succeeds seconds later.
    # Observed on a connect that then worked perfectly. Matching it would
    # report a failure on every healthy tunnel.
    #
    # What separates the two is the state the transition came *from*.
    # Connecting to WaitingForIdentity is a sign-in starting normally;
    # Reconnecting to WaitingForIdentity is an automatic retry meeting a
    # challenge it cannot answer, which is the case worth reporting.
    def parse(text : String) : Reading?
      found : Reading? = nil
      scanned = 0

      text.lines.reverse_each do |line|
        scanned += 1
        break if scanned > MAX_LINES

        cause = cause_in(line)
        next unless cause
        at = timestamp_in(line)
        next unless at

        if already = found
          # Bounded by time rather than by the next marker: a teardown emits
          # several transitions, so stopping at the first one that is not a
          # local network change would usually stop on a sibling of the one
          # already found.
          break if already.at - at > CONSEQUENCE_WINDOW

          # A sign-in demand is the visible end of a local network change, and
          # reporting the demand alone sends a reader to fix the wrong thing.
          if already.cause.sign_in_required? && cause.local_network_changed?
            found = Reading.new(
              at: at, cause: Cause::LocalNetworkChanged, needs_sign_in: true
            )
            break
          end
        else
          found = Reading.new(
            at: at, cause: cause, needs_sign_in: cause.sign_in_required?
          )
        end
      end

      found
    end

    private def cause_in(line : String) : Cause?
      return Cause::LocalNetworkChanged if line.includes?(LOCAL_NETWORK)
      return Cause::SignInRequired if line.includes?(NEEDS_IDENTITY)
      return Cause::ServerAddressRejected if line.includes?(ADDRESS_REJECTED)
      nil
    end

    # The leading instant, which carries fractional seconds.
    private def timestamp_in(line : String) : Time?
      field = line.split(' ', 2).first?
      return nil unless field
      Time.parse_rfc3339(field)
    rescue ex : Time::Format::Error | ArgumentError
      nil
    end
  end
end
