# start_supervisor_daemon.cr
#
# Daemonize via fork(2) + setsid(2): the child detaches from the
# controlling terminal and redirects stdio to the log file.
# Returns the child's PID to the parent, nil in the child.

module Procodile
  module Daemon
    # Fork the current process. The parent receives the child's PID;
    # the child detaches from the terminal, redirects stdio, and returns nil.
    def self.daemonize!(config : Config) : Int64?
      pid = LibC.fork

      case pid
      when -1
        raise Error.new("Cannot daemonize: fork failed")
      when 0
        # Child: create a new session to detach from the controlling terminal.
        if LibC.setsid < 0
          raise Error.new("Cannot daemonize: failed to detach from controlling terminal.")
        end

        # Redirect stdio to the log file.
        log_file = File.open(config.log_path, "a")
        log_fd = log_file.fd
        LibC.dup2(log_fd, 0) # stdin
        LibC.dup2(log_fd, 1) # stdout
        LibC.dup2(log_fd, 2) # stderr
        log_file.close if log_fd > 2

        nil
      else
        pid.to_i64
      end
    end
  end

  lib LibC
    fun fork : Int32
    fun setsid : Int32
    fun dup2(oldfd : Int32, newfd : Int32) : Int32
  end
end
