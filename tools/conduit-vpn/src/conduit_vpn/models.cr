require "json"

module ConduitVPN
  # Decoders for the AWS VPN Client's JSON output.
  #
  # MIRROR: ConduitApp/ConduitApp/Models/VPNTypes.swift
  module Models
    extend self

    # The client emits a uniform error envelope — {"status":"Error",
    # "message":"..."} — on stdout, with exit 1. Reading the message from
    # stderr finds nothing.
    #
    # Returns nil when the payload is not that envelope, so a caller can
    # fall back to reporting the exit code rather than inventing a message
    # from output it failed to understand.
    def error_message(payload : String) : String?
      parsed = JSON.parse(payload)
      return nil unless parsed.as_h?
      parsed["message"]?.try(&.as_s?)
    rescue JSON::ParseException
      nil
    end
  end
end
