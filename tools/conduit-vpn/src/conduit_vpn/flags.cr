module ConduitVPN
  # Separates Conduit's own flags from everything destined for the client.
  #
  # A general-purpose option parser is the wrong tool here: it would have to
  # be taught every flag the client accepts in order to pass them through, and
  # would reject the ones it had not been taught yet. Recognizing a short
  # fixed list and forwarding the remainder untouched keeps a future client
  # release working without a change here.
  module Flags
    extend self

    record Split,
      wait : Bool,
      yes : Bool,
      json : Bool,
      timeout : String?,
      forward : Array(String)

    def split(argv : Array(String)) : Split
      wait = false
      yes = false
      json = false
      timeout : String? = nil
      forward = [] of String

      index = 0
      while index < argv.size
        argument = argv[index]

        case argument
        when "--wait"
          wait = true
        when "--yes", "-y"
          yes = true
        when "--json"
          json = true
        when "--timeout"
          index += 1
          timeout = argv[index]?
        else
          if argument.starts_with?("--timeout=")
            timeout = argument.split('=', 2)[1]
          else
            forward << argument
          end
        end

        index += 1
      end

      Split.new(
        wait: wait,
        yes: yes,
        json: json,
        timeout: timeout,
        forward: forward,
      )
    end

    # Value of a `--flag value` or `--flag=value` pair, or nil.
    def value_of(argv : Array(String), name : String) : String?
      argv.each_with_index do |argument, index|
        return argv[index + 1]? if argument == name
        if argument.starts_with?("#{name}=")
          return argument.split('=', 2)[1]
        end
      end
      nil
    end
  end
end
