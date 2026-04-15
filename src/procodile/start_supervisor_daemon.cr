# start_supervisor_daemon.cr
#
# Daemonize by re-exec: spawn a real OS child process and return its PID.
# The child re-runs the normal CLI path; we only mark it via ENV.

module Procodile
  module Daemon
    ENV_KEY = "PROCODILE_DAEMON_CHILD"

    # True when running in the re-exec'ed daemon child.
    def self.child? : Bool
      ENV[ENV_KEY]? == "1"
    end

    def self.detach_child! : Nil
      if LibC.setsid < 0
        raise Error.new("Cannot daemonize: failed to detach supervisor from the controlling terminal.")
      end
    end

    # Spawn a daemon child (same executable, same argv), redirecting output to log.
    # Returns the child's PID. Also does a tiny sanity check that the PID exists.
    def self.daemonize!(config : Config) : Int64
      exe = ::Process.executable_path

      raise Error.new("Cannot daemonize: failed to determine the current executable path.") unless exe

      log_path = File.open(config.log_path, "a")

      child = ::Process.new(
        [exe, *Procodile::ORIGINAL_ARGV.dup],
        output: log_path,
        error: log_path,
        env: {ENV_KEY => "1"}
      )

      # Close the fd in the parent, sub-process will continue write log.
      log_path.close

      child.pid
    end
  end

  lib LibC
    fun setsid : Int32
  end
end
