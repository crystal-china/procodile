require "./start_supervisor_daemon"

module Procodile
  class Supervisor
    def self.start(
      config : Config,
      options : CLI::Options = CLI::Options.new,
      &after_start : Proc(Supervisor, Nil)
    ) : Nil
      run_options = Supervisor::RunOptions.new(
        respawn: options.respawn?,
        stop_when_none: options.stop_when_none?,
        proxy: options.proxy?,
        force_single_log: options.foreground?,
        port_allocations: options.port_allocations,
        env_file: options.env_file,
        foreground: !!options.foreground?
      )

      tidy_pids(config)

      if options.clean?
        FileUtils.rm_rf(Dir[File.join(config.pid_root, "*")])
        puts "Emptied PID directory"
      end

      if !Dir[File.join(config.pid_root, "*")].empty?
        raise Error.new "The PID directory (#{config.pid_root}) is not empty. \
Cannot start unless things are clean."
      end

      if options.foreground?
        set_process_title("[procodile] #{config.app_name} (#{config.root})")
        File.write(config.supervisor_pid_path, ::Process.pid)
        Supervisor.new(config, run_options).start(after_start)
      else
        FileUtils.rm_rf(File.join(config.pid_root, "*.pid"))
        if (pid = Procodile::Daemon.daemonize!(config))
          # Parent: report the child PID. Runtime issues are checked in dispatch.
          puts "Started Procodile supervisor with PID #{pid}"
        else
          # Child: set up and start the supervisor.
          set_process_title("[procodile] #{config.app_name} (#{config.root})")
          File.write(config.supervisor_pid_path, ::Process.pid)
          Supervisor.new(config, run_options).start(after_start)
        end
      end
    end

    # Clean up procodile.pid and procodile.sock with all unused pid files
    private def self.tidy_pids(config : Config) : Nil
      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(config.sock_path)

      pid_files = Dir[File.join(config.pid_root, "*.pid")]

      pid_files.each do |pid_path|
        file_name = pid_path.split("/").last
        pid = File.read(pid_path).to_i

        if ::Process.exists?(pid)
          puts "Could not remove #{file_name} because process (#{pid}) was active"
        else
          FileUtils.rm_rf(pid_path)
          puts "Removed #{file_name} because process was not active"
        end
      end
    end

    private def self.set_process_title(title : String) : Nil
      # Set process title in platform-specific ways.
      {% if flag?(:linux) %}
        if LibC.prctl(LibC::PR_SET_NAME, title, 0, 0, 0) != 0
          Procodile.log "system", "Failed to set process title: #{Errno.value}"
        end
      {% elsif flag?(:darwin) %}
        LibC.setprogname(title)
      {% else %}
        Procodile.log "system", "Setting process title is not supported on this platform"
      {% end %}
    end
  end

  {% if flag?(:linux) %}
    lib LibC
      PR_SET_NAME = 15

      fun prctl(option : Int32, name : UInt8*, arg3 : UInt64, arg4 : UInt64, arg5 : UInt64) : Int32
    end
  {% end %}

  {% if flag?(:darwin) %}
    lib LibC
      fun setprogname(progname : UInt8*) : Void
    end
  {% end %}
end
