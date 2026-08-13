require "spec"
require "file_utils"

# Reach the library without also running the program. Integration examples
# invoke the built binary as a subprocess instead — exit codes and stream
# handling are only observable from outside the process.
ENV["CONDUIT_SKIP_CLI"] = "1"

require "../src/conduit_vpn"

module SpecHelper
  extend self

  BINARY      = File.expand_path("../build/conduit-vpn", __DIR__)
  FAKE_CLIENT = File.expand_path("fixtures/bin/aws-vpn-client", __DIR__)

  record Result, stdout : String, stderr : String, exit_code : Int32 do
    def success? : Bool
      exit_code == 0
    end
  end

  # One example's isolated world: a private CONDUIT_ROOT, a directory of
  # canned client responses, and a log of every client invocation.
  class Sandbox
    getter root : Path
    getter responses : Path
    getter call_log : Path

    def initialize(@root : Path)
      @responses = @root / "responses"
      @call_log = @root / "calls.log"
      Dir.mkdir_p(@responses.to_s)
    end

    # Queue stdout for successive calls to one subcommand. The last entry
    # repeats once the sequence is exhausted.
    def respond(subcommand : String, *payloads : String) : Nil
      payloads.to_a.each_with_index(1) do |payload, index|
        File.write((@responses / "#{subcommand}.#{index}").to_s, payload)
      end
    end

    def calls : Array(String)
      return [] of String unless File.exists?(@call_log.to_s)
      File.read_lines(@call_log.to_s)
    end

    def client_home : Path
      @root / "client-home"
    end

    # Where settings land, given the CONDUIT_ROOT below. Its *absence* is the
    # useful assertion: the file is only created when a value is written, so a
    # command that should not have written one leaves nothing here.
    def config_file : Path
      @root / "config.json"
    end

    def env : Hash(String, String?)
      {
        "CONDUIT_ROOT"        => @root.to_s,
        "CONDUIT_CLIENT_PATH" => FAKE_CLIENT,
        "FAKE_VPN_RESPONSES"  => @responses.to_s,
        "FAKE_VPN_CALL_LOG"   => @call_log.to_s,
        # Crystal merges `env` into the parent's environment, so the guard
        # set above would otherwise reach the binary under test and make it
        # exit before doing anything. A nil value unsets the variable.
        "CONDUIT_SKIP_CLI" => nil,
      } of String => String?
    end
  end

  def sandbox(&)
    dir = File.tempname("conduit-spec")
    Dir.mkdir_p(dir)

    # Temporary directories on this platform sit behind symlinked parents.
    # The client-home check compares a resolved path against a literal one,
    # so an unresolved root would fail it for reasons unrelated to the
    # behavior under test — and would hide a real regression in that check.
    real = Path.new(File.realpath(dir))

    begin
      yield Sandbox.new(real)
    ensure
      FileUtils.rm_rf(real.to_s)
    end
  end

  # In-process equivalent of `sandbox`, for examples that exercise the library
  # directly rather than through the built binary.
  def with_root(&)
    dir = File.tempname("conduit-unit")
    Dir.mkdir_p(dir)
    real = Path.new(File.realpath(dir))
    begin
      with_env({"CONDUIT_ROOT" => real.to_s, "CONDUIT_CONFIG" => nil}) do
        yield real
      end
    ensure
      FileUtils.rm_rf(real.to_s)
    end
  end

  def write_config(root : Path, body : String) : Nil
    File.write((root / "config.json").to_s, body)
  end

  def run(sandbox : Sandbox, args : Array(String),
          extra_env : Hash(String, String?) = {} of String => String?) : Result
    invoke(args, sandbox.env.merge(extra_env))
  end

  def invoke(args : Array(String), env : Hash(String, String?)) : Result
    unless File::Info.executable?(BINARY)
      raise "conduit-vpn not built at #{BINARY} — run `make dev` first"
    end

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(BINARY, args, env: env, output: stdout, error: stderr)
    Result.new(stdout.to_s, stderr.to_s, status.exit_code)
  end

  # Set environment variables for the duration of a block, restoring exactly
  # what was there before — including absence, which is distinct from empty.
  def with_env(vars : Hash(String, String?), &)
    previous = vars.keys.to_h { |key| {key, ENV[key]?} }
    vars.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
    begin
      yield
    ensure
      previous.each { |key, value| value ? (ENV[key] = value) : ENV.delete(key) }
    end
  end
end
