require "json"

module ConduitVPN
  # Decoders for the AWS VPN Client's JSON output.
  #
  # MIRROR: ConduitApp/ConduitApp/Models/VPNTypes.swift
  #
  # One field the client returns is deliberately absent from every type here:
  # the account that initiated a connection. Conduit has no use for it, and a
  # field that does not exist cannot be printed by accident into a log, an
  # error message, or a bug report.
  module Models
    extend self

    enum Status
      NotConnected
      Connecting
      WaitingForIdentity
      Connected
      Disconnecting
      Reconnecting

      # Returns nil for a status this build does not know. A client release
      # that adds one should leave Conduit reporting something honest rather
      # than aborting mid-poll.
      def self.from_client?(raw : String) : Status?
        parse?(raw)
      end

      # The two states the client settles into. Everything else is a
      # transition that will resolve on its own.
      def resting? : Bool
        not_connected? || connected?
      end

      def transitional? : Bool
        !resting?
      end

      def label : String
        case self
        in .not_connected?        then "not connected"
        in .connecting?           then "connecting"
        in .waiting_for_identity? then "waiting for sign-in"
        in .connected?            then "connected"
        in .disconnecting?        then "disconnecting"
        in .reconnecting?         then "reconnecting"
        end
      end
    end

    struct ByteCounters
      include JSON::Serializable

      @[JSON::Field(key: "tunnel-bytes-in")]
      getter tunnel_in : Int64

      @[JSON::Field(key: "tunnel-bytes-out")]
      getter tunnel_out : Int64

      @[JSON::Field(key: "transport-bytes-in")]
      getter transport_in : Int64

      @[JSON::Field(key: "transport-bytes-out")]
      getter transport_out : Int64
    end

    struct Attempt
      include JSON::Serializable

      @[JSON::Field(key: "updated-at")]
      getter updated_at : String?

      # Absent for an idle profile, and present with every counter zero for a
      # stalled one — so its presence says nothing about whether a tunnel
      # exists. Optional rather than zero-defaulted because the client itself
      # emits the all-zero payload, which a zero default would be
      # indistinguishable from, and both read as a live tunnel moving no bytes.
      getter details : ByteCounters?
    end

    struct ConnectionStatus
      include JSON::Serializable

      @[JSON::Field(key: "connection-status")]
      getter raw_status : String

      @[JSON::Field(key: "latest-connection-attempt")]
      getter attempt : Attempt?

      def status : Status?
        Status.from_client?(raw_status)
      end
    end

    struct Profile
      include JSON::Serializable

      @[JSON::Field(key: "profile-name")]
      getter name : String

      @[JSON::Field(key: "auth-type")]
      getter auth_type : String?

      @[JSON::Field(key: "imported-at")]
      getter imported_at : String?
    end

    # Only non-disconnected profiles appear in a connection listing, so
    # absence from one is itself the answer: that profile is not connected.
    struct Connection
      include JSON::Serializable

      @[JSON::Field(key: "profile-name")]
      getter name : String

      @[JSON::Field(key: "connection-status")]
      getter raw_status : String

      @[JSON::Field(key: "last-updated-at")]
      getter updated_at : String?

      def status : Status?
        Status.from_client?(raw_status)
      end
    end

    struct Preferences
      include JSON::Serializable

      @[JSON::Field(key: "max-connections")]
      getter max_connections : Int32?
    end

    def profiles(payload : String) : Array(Profile)
      Array(Profile).from_json(payload)
    end

    def connections(payload : String) : Array(Connection)
      Array(Connection).from_json(payload)
    end

    def connection_status(payload : String) : ConnectionStatus
      ConnectionStatus.from_json(payload)
    end

    def preferences(payload : String) : Preferences
      Preferences.from_json(payload)
    end

    # The client emits a uniform error envelope — {"status":"Error",
    # "message":"..."} — on stdout, with exit 1. Reading stderr finds nothing.
    #
    # Returns nil when the payload is not that envelope, so a caller can fall
    # back to reporting the exit code rather than inventing a message from
    # output it did not understand.
    def error_message(payload : String) : String?
      parsed = JSON.parse(payload)
      return nil unless parsed.as_h?
      parsed["message"]?.try(&.as_s?)
    rescue JSON::ParseException
      nil
    end

    def time(raw : String?) : Time?
      return nil unless raw
      Time.parse_rfc3339(raw)
    rescue
      nil
    end
  end
end
