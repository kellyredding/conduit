require "../spec_helper"

private alias Models = ConduitVPN::Models

describe ConduitVPN::Models do
  describe "Status" do
    it "reads the names the client actually emits" do
      Models::Status.from_client?("NotConnected")
        .should eq(Models::Status::NotConnected)
      Models::Status.from_client?("WaitingForIdentity")
        .should eq(Models::Status::WaitingForIdentity)
      Models::Status.from_client?("Reconnecting")
        .should eq(Models::Status::Reconnecting)
    end

    # A client release that adds a state should leave Conduit reporting
    # something honest rather than aborting in the middle of a poll.
    it "returns nothing for a state this build does not know" do
      Models::Status.from_client?("Teleporting").should be_nil
    end

    it "separates the states the client settles into from the transitions" do
      Models::Status::Connected.resting?.should be_true
      Models::Status::NotConnected.resting?.should be_true
      Models::Status::Connecting.transitional?.should be_true
      Models::Status::WaitingForIdentity.transitional?.should be_true
      Models::Status::Disconnecting.transitional?.should be_true
    end
  end

  describe ".profiles" do
    it "decodes a listing" do
      profiles = Models.profiles(<<-JSON)
      [
        {"profile-name": "Alpha", "owned-by": "someone",
         "auth-type": "saml", "imported-at": "2026-01-01T00:00:00-05:00"},
        {"profile-name": "Bravo", "owned-by": "someone",
         "auth-type": "saml", "imported-at": "2026-01-02T00:00:00-05:00"}
      ]
      JSON

      profiles.map(&.name).should eq(["Alpha", "Bravo"])
      profiles.first.auth_type.should eq("saml")
    end

    it "decodes an empty listing" do
      Models.profiles("[]").should be_empty
    end
  end

  describe ".connection_status" do
    it "decodes a live tunnel with its counters" do
      status = Models.connection_status(<<-JSON)
      {
        "connection-status": "Connected",
        "latest-connection-attempt": {
          "initiated-by": "someone",
          "updated-at": "2026-01-01T00:00:00-05:00",
          "details": {
            "tunnel-bytes-in": 164676, "tunnel-bytes-out": 1402734,
            "transport-bytes-in": 1487826, "transport-bytes-out": 245520
          }
        }
      }
      JSON

      status.status.should eq(Models::Status::Connected)
      status.attempt.should_not be_nil
      status.attempt.not_nil!.details.not_nil!.tunnel_in.should eq(164676)
    end

    # Counters must stay absent rather than defaulting to zero: zeroes read as
    # a live tunnel that has carried no traffic, which is a different claim.
    it "leaves counters absent when the profile is not connected" do
      status = Models.connection_status(<<-JSON)
      {
        "connection-status": "NotConnected",
        "latest-connection-attempt": {
          "initiated-by": "someone",
          "updated-at": "2026-01-01T00:00:00-05:00"
        }
      }
      JSON

      status.status.should eq(Models::Status::NotConnected)
      status.attempt.not_nil!.details.should be_nil
    end

    it "decodes a response carrying no attempt at all" do
      status = Models.connection_status(%({"connection-status": "NotConnected"}))
      status.attempt.should be_nil
    end

    it "keeps the raw text of a state it cannot name" do
      status = Models.connection_status(%({"connection-status": "Teleporting"}))
      status.status.should be_nil
      status.raw_status.should eq("Teleporting")
    end
  end

  describe ".connections" do
    it "decodes active connections" do
      connections = Models.connections(<<-JSON)
      [
        {"profile-name": "Bravo", "initiated-by": "someone",
         "connection-status": "Connected",
         "last-updated-at": "2026-01-01T00:00:00-05:00"}
      ]
      JSON

      connections.size.should eq(1)
      connections.first.name.should eq("Bravo")
      connections.first.status.should eq(Models::Status::Connected)
    end
  end

  describe ".error_message" do
    it "reads the client's error envelope" do
      Models.error_message(%({"status": "Error", "message": "Profile not found"}))
        .should eq("Profile not found")
    end

    it "returns nothing for output that is not an envelope" do
      Models.error_message(%([{"profile-name": "Alpha"}])).should be_nil
      Models.error_message("not json at all").should be_nil
      Models.error_message("").should be_nil
    end
  end

  describe ".time" do
    it "parses the offsets the client emits" do
      Models.time("2026-01-01T12:00:00-05:00").should_not be_nil
    end

    it "returns nothing rather than raising on unusable input" do
      Models.time(nil).should be_nil
      Models.time("whenever").should be_nil
    end
  end
end
