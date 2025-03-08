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

      set_process_title("[procodile] #{config.app_name} (#{config.root})")

      if options.foreground?
        File.write(config.supervisor_pid_path, ::Process.pid)

        Supervisor.new(config, run_options).start(after_start)
      else
        FileUtils.rm_rf(File.join(config.pid_root, "*.pid"))

        process = ::Process.fork do
          log_path = File.open(config.log_path, "a")
          STDOUT.reopen(log_path); STDOUT.sync = true
          STDERR.reopen(log_path); STDERR.sync = true

          Supervisor.new(config, run_options).start(after_start)
        end

        spawn { process.wait }

        pid = process.pid
        File.write(config.supervisor_pid_path, pid)

        puts "Started Procodile supervisor with PID #{pid}"
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
      # Set $PROGRAM_NAME in linux
      File.write("/proc/self/comm", title)
    end
  end
end
