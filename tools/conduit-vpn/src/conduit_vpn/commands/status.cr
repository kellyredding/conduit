module ConduitVPN
  module Commands
    # Every profile in one view, which the client cannot produce: it lists
    # profiles and connections separately, and only non-disconnected profiles
    # appear in the second. Merging them is the whole command.
    module Status
      extend self

      record Row,
        name : String,
        status : Models::Status?,
        raw_status : String,
        updated_at : String?,
        sensitive : Bool do
        def label : String
          status.try(&.label) || raw_status
        end
      end

      def run(argv : Array(String)) : Int32
        as_json = argv.includes?("--json")

        CLI.guard do
          client = Client.from_config
          rows = collect(client)

          if as_json
            STDOUT.puts as_json_document(rows)
          elsif rows.empty?
            STDOUT.puts "No profiles are installed."
          else
            STDOUT.print render(rows)
          end

          CLI::OK
        end
      end

      private def collect(client : Client) : Array(Row)
        profiles = Models.profiles(client.capture(["list-profiles"]))
        connections = Models.connections(client.capture(["list-connections"]))
        by_name = connections.to_h { |connection| {connection.name, connection} }

        profiles.map do |profile|
          connection = by_name[profile.name]?

          Row.new(
            name: profile.name,
            # Absence from the connection listing is itself the answer.
            status: connection ? connection.status : Models::Status::NotConnected,
            raw_status: connection.try(&.raw_status) || "NotConnected",
            updated_at: connection.try(&.updated_at),
            sensitive: Sensitivity.sensitive?(profile.name),
          )
        end
      end

      # Built by hand rather than derived from the row type. The key names are
      # a published interface for scripts, and hyphenated to match the shapes
      # the client already emits, so they should not shift because a field was
      # renamed internally.
      private def as_json_document(rows : Array(Row)) : String
        JSON.build(indent: "  ") do |json|
          json.array do
            rows.each do |row|
              json.object do
                json.field "profile-name", row.name
                json.field "connection-status", row.raw_status
                json.field "connected", !!row.status.try(&.connected?)
                json.field "sensitive", row.sensitive
                json.field "updated-at", row.updated_at
              end
            end
          end
        end
      end

      private def render(rows : Array(Row)) : String
        name_width = rows.map(&.name.size).max.clamp(7, Int32::MAX)
        status_width = rows.map(&.label.size).max.clamp(6, Int32::MAX)

        # A timestamp only exists for a profile that appears in the connection
        # listing, so with nothing connected the column is entirely dashes.
        # Dropping it then removes a column that carries no information rather
        # than lining up placeholders under a heading.
        timestamps = rows.any? { |row| row.updated_at }

        String.build do |io|
          io << "  " << "PROFILE".ljust(name_width)
          io << "  " << (timestamps ? "STATUS".ljust(status_width) : "STATUS")
          io << "  " << "UPDATED" if timestamps
          io << '\n'

          rows.each do |row|
            io << (row.sensitive ? "! " : "  ")
            io << row.name.ljust(name_width)
            io << "  " << (timestamps ? row.label.ljust(status_width) : row.label)
            io << "  " << stamp(row.updated_at) if timestamps
            io << '\n'
          end

          if rows.any?(&.sensitive)
            io << "\n! needs --yes to connect\n"
          end
        end
      end

      private def stamp(raw : String?) : String
        time = Models.time(raw)
        return "—" unless time
        time.to_local.to_s("%Y-%m-%d %H:%M")
      end
    end
  end
end
