# start_supervisor_daemon.cr
#
# This file ONLY handles daemonization via re-exec + OS child process.
# It does NOT attempt to run Supervisor itself inside this helper,
# because after exec, parent memory (config/run_options/after_start) is gone.
#
# Integration steps (minimal changes):
# 1) Require this file early (before CLI parsing), and call:
#      Procodile::Daemon.consume_child_marker!
#    so the internal arg doesn't break your CLI parser.
#
# 2) In your original Supervisor.start background branch (the old fork branch),
#    replace it with:
#      Procodile::Daemon.daemonize!(config)
#      puts "Started Procodile supervisor with PID #{Procodile::Daemon.last_child_pid.not_nil!}"
#    and return.
#
# 3) In Supervisor.start, treat daemon child like "foreground execution"
#    (i.e. do NOT spawn another child). You can do that by checking
#    Procodile::Daemon.child? in the same place you already branch on options.foreground?.
#
#    Child process will parse CLI, rebuild config/options/run_options,
#    and then execute Supervisor.new(...).start(after_start) normally.

module Procodile
  module Daemon
    CHILD_ARG = "--__procodile-supervisor-child"

    @@is_child = false
    @@last_child_pid : Int64? = nil

    # Call before CLI parsing to avoid unknown-arg errors.
    def self.consume_child_marker! : Bool
      if (i = ARGV.index(CHILD_ARG))
        ARGV.delete_at(i)
        @@is_child = true
      else
        @@is_child = false
      end
      @@is_child
    end

    # Fallback for cases where you can't consume ARGV early.
    def self.child? : Bool
      @@is_child || ENV["PROCODILE_DAEMON_CHILD"]? == "1"
    end

    def self.last_child_pid : Int64?
      @@last_child_pid
    end

    # Spawn a REAL OS child process by re-execing the current executable.
    #
    # Parent responsibilities:
    #   - open log file
    #   - spawn child with CHILD_ARG prepended to ARGV
    #   - write pidfile (supervisor_pid_path)
    #
    # Child responsibilities (handled by your existing code path):
    #   - parse CLI, reconstruct config/options/run_options
    #   - enter Supervisor.start; it will detect Daemon.child? and run supervisor in-process
    def self.daemonize!(config : Config) : Nil
      exe = ::Process.executable_path
      raise Error.new("Cannot daemonize: Process.executable_path is nil") unless exe

      child_args =  ARGV.dup

      log_path = File.open(config.log_path, "a")

      child = ::Process.new(
                            exe,
                            child_args,
                            output: log_path,
                            error:  log_path,
                            env: {"PROCODILE_DAEMON_CHILD" => "1"}
                            )

      @@last_child_pid = child.pid
      File.write(config.supervisor_pid_path, child.pid)
    end

    def self.wait_for_socket(sock_path : String, timeout : Time::Span = 3.seconds, interval : Time::Span = 50.milliseconds) : Nil
      deadline = Time.monotonic + timeout
      last_error : Exception? = nil

      while Time.monotonic < deadline
        begin
          if File.exists?(sock_path)
            UNIXSocket.new(sock_path).close
            return
          end
        rescue ex : Exception
          last_error = ex
        end
        sleep interval
      end

      raise Error.new("Supervisor control socket not ready: #{sock_path} (waited #{timeout}). Last error: #{last_error}")
    end
  end
end
