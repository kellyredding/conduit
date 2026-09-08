require "../spec_helper"

# Fixture profile names are invented and no fixture carries an address. The
# parser locates markers without interpreting the fields around them, so an
# empty bracket exercises the same path a real subnet would.
#
# The two negative examples are the ones that matter most here. A parser that
# announced a failure on every healthy connect would be worse than none, and
# both traps below look exactly like evidence until the surrounding lines are
# read.
LOCAL_NET_LOG = <<-LOG
  2026-01-02T03:04:05.100000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new subnets detected new_cidrs=[]
  2026-01-02T03:04:05.200000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new LAN detected, stopping session
  2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Alpha
  LOG

# A federated sign-in *begins* with an AUTH_FAILED and a challenge — observed
# on a connect that went on to work two seconds later.
NORMAL_SIGN_IN_LOG = <<-LOG
  2026-01-02T03:04:05.000000Z  INFO ThreadId(99) connection: OpenVPN callback Log(OvpnLog { text: "AUTH_FAILED\\n" }) profile=Alpha
  2026-01-02T03:04:05.100000Z  INFO ThreadId(99) connection: OpenVPN callback Event(OvpnEvent { error: true, fatal: true, name: "DYNAMIC_CHALLENGE", info: "CRV1:R:opaque" }) profile=Alpha
  2026-01-02T03:04:05.200000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Connecting new_state=WaitingForIdentity connection_id=1 profile=Alpha
  2026-01-02T03:04:12.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Connecting new_state=Connected connection_id=1 profile=Alpha
  LOG

# The server pushes this option on every successful connect, so matching the
# words reports a keepalive timeout on every good tunnel.
PUSHED_OPTIONS_LOG = <<-LOG
  2026-01-02T03:04:05.000000Z  INFO ThreadId(99) connection: OpenVPN callback Log(OvpnLog { text: "OPTIONS:\\n0 [ping-restart] [120]\\n1 [comp-lzo] [no]\\n" }) profile=Alpha
  LOG

TWO_SESSIONS_LOG = <<-LOG
  2026-01-02T01:00:00.000000Z  INFO tokio-rt-worker ThreadId(13) LocalNet: new LAN detected, stopping session
  2026-01-02T05:00:00.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Bravo
  LOG

describe ConduitVPN::DaemonTeardown do
  describe ".parse" do
    it "reads a local network change as the cause" do
      reading = ConduitVPN::DaemonTeardown.parse(LOCAL_NET_LOG)
      reading.should_not be_nil
      reading.not_nil!.cause
        .should eq(ConduitVPN::DaemonTeardown::Cause::LocalNetworkChanged)
    end

    it "reports the sign-in it caused as the consequence, not the cause" do
      ConduitVPN::DaemonTeardown.parse(LOCAL_NET_LOG)
        .not_nil!.needs_sign_in.should be_true
    end

    it "times it from the initiating event rather than the sign-in" do
      ConduitVPN::DaemonTeardown.parse(LOCAL_NET_LOG).not_nil!.at
        .should eq(Time.parse_rfc3339("2026-01-02T03:04:05.200000Z"))
    end

    it "does not treat a sign-in that is merely starting as a teardown" do
      ConduitVPN::DaemonTeardown.parse(NORMAL_SIGN_IN_LOG).should be_nil
    end

    it "does not treat a pushed ping-restart option as a teardown" do
      ConduitVPN::DaemonTeardown.parse(PUSHED_OPTIONS_LOG).should be_nil
    end

    it "reads a reconnect that meets a challenge as a teardown" do
      log = <<-LOG
        2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ConnectionStatus state transition old_state=Reconnecting new_state=WaitingForIdentity connection_id=1 profile=Bravo
        LOG

      ConduitVPN::DaemonTeardown.parse(log).not_nil!.cause
        .should eq(ConduitVPN::DaemonTeardown::Cause::SignInRequired)
    end

    it "reads a rejected server address as its own cause" do
      log = <<-LOG
        2026-01-02T03:04:06.000000Z  INFO ThreadId(99) connection: ServerIpValidationFailed profile=Bravo
        LOG

      ConduitVPN::DaemonTeardown.parse(log).not_nil!.cause
        .should eq(ConduitVPN::DaemonTeardown::Cause::ServerAddressRejected)
    end

    it "yields nothing for an empty log" do
      ConduitVPN::DaemonTeardown.parse("").should be_nil
    end

    it "yields nothing for text carrying no marker" do
      ConduitVPN::DaemonTeardown
        .parse("2026-01-02T03:04:05.000000Z  INFO nothing happened here")
        .should be_nil
    end

    it "does not adopt an older unrelated teardown as the cause of a newer one" do
      ConduitVPN::DaemonTeardown.parse(TWO_SESSIONS_LOG).not_nil!.cause
        .should eq(ConduitVPN::DaemonTeardown::Cause::SignInRequired)
    end
  end

  describe ".newest_log" do
    it "chooses the live log over a rotation" do
      SpecHelper.with_root do |dir|
        File.write((dir / "aws_vpn_client_daemon_20260830.log").to_s, LOCAL_NET_LOG)
        File.write((dir / "aws_vpn_client_daemon_20260830.log.1").to_s, TWO_SESSIONS_LOG)

        ConduitVPN::DaemonTeardown.newest_log(dir).not_nil!.basename
          .should eq("aws_vpn_client_daemon_20260830.log")
      end
    end

    it "yields nothing for a directory that is not there" do
      SpecHelper.with_root do |dir|
        ConduitVPN::DaemonTeardown.newest_log(dir / "missing").should be_nil
      end
    end
  end

  describe ".latest" do
    it "reads the teardown recorded in a directory" do
      SpecHelper.with_root do |dir|
        File.write((dir / "aws_vpn_client_daemon_20260830.log").to_s, LOCAL_NET_LOG)

        ConduitVPN::DaemonTeardown.latest(dir).not_nil!.cause
          .should eq(ConduitVPN::DaemonTeardown::Cause::LocalNetworkChanged)
      end
    end

    it "yields nothing rather than failing when there is no log" do
      SpecHelper.with_root do |dir|
        ConduitVPN::DaemonTeardown.latest(dir).should be_nil
      end
    end
  end

  describe ".tail" do
    it "drops the partial line an offset in bytes lands in" do
      SpecHelper.with_root do |dir|
        file = dir / "tail.txt"
        File.write(file.to_s, "first line\nsecond line\nthird line\n")

        ConduitVPN::DaemonTeardown.tail(file, bytes: 16).not_nil!
          .starts_with?("third line").should be_true
      end
    end

    it "keeps the first line when the window covers the whole file" do
      SpecHelper.with_root do |dir|
        file = dir / "tail.txt"
        File.write(file.to_s, "first line\nsecond line\nthird line\n")

        ConduitVPN::DaemonTeardown.tail(file, bytes: 4096).not_nil!
          .starts_with?("first line").should be_true
      end
    end
  end
end
