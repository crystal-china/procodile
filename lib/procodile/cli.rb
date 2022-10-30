require "fileutils"
require "procodile/version"
require "procodile/error"
require "procodile/message"
# require "procodile/rbenv"
require "procodile/supervisor"
require "procodile/signal_handler"
require "procodile/control_client"

require "procodile/commands/help_command"
require "procodile/commands/start_command"
require "procodile/commands/stop_command"
require "procodile/commands/restart_command"
require "procodile/commands/reload_command"
require "procodile/commands/check_concurrency_command"
require "procodile/commands/status_command"
require "procodile/commands/kill_command"
require "procodile/commands/exec_command"
require "procodile/commands/console_command"
require "procodile/commands/log_command"

module Procodile
  class CLI
    attr_accessor :options, :config

    def self.commands
      @commands ||= {}
    end

    def self.options(&block)
      @options = block
    end

    def self.command(name, description, callable)
      commands[name] = {
        :name => name,
        :description => description,
        :options => @options,
        :callable => callable
      }

      @options = nil
    end

    def initialize
      @options = {}
    end

    def dispatch(command)
      if self.class.commands.key?(command.to_sym)
        self.class.commands[command.to_sym][:callable].bind(self).call
      else
        raise Error, "Invalid command '#{command}'"
      end
    end

    #
    # Help
    #

    include Procodile::CLI::HelpCommand

    #
    # Start
    #

    include Procodile::CLI::StartCommand


    #
    # Stop
    #

    include Procodile::CLI::StopCommand

    #
    # Restart
    #

    include Procodile::CLI::RestartCommand

    #
    # Reload Config
    #

    include Procodile::CLI::ReloadCommand

    #
    # Check process concurrency
    #

    include Procodile::CLI::CheckConcurrencyCommand

    #
    # Status
    #

    include Procodile::CLI::StatusCommand

    #
    # Kill
    #

    include Procodile::CLI::KillCommand

    #
    # Run a command with a procodile environment
    #

    include Procodile::CLI::ExecCommand

    #
    # Run the configured console command
    #

    include Procodile::CLI::ConsoleCommand

    #
    # Open up the procodile log if it exists
    #

    include Procodile::CLI::LogCommand

    # ============================== private ==============================

    private

    def supervisor_running?
      if pid = current_pid
        self.class.pid_active?(pid)
      else
        false
      end
    end

    def current_pid
      if File.exist?(@config.supervisor_pid_path)
        pid_file = File.read(@config.supervisor_pid_path).strip
        pid_file.empty? ? nil : pid_file.to_i
      end
    end

    def self.pid_active?(pid)
      ::Process.getpgid(pid) ? true : false
    rescue Errno::ESRCH
      false
    end

    def process_names_from_cli_option
      if @options[:processes]
        processes = @options[:processes].split(",")
        if processes.empty?
          raise Error, "No process names provided"
        end

        # processes.each do |process|
        #  process_name, _ = process.split('.', 2)
        #  unless @config.process_list.keys.include?(process_name.to_s)
        #    raise Error, "Process '#{process_name}' is not configured. You may need to reload your config."
        #  end
        # end
        processes
      end
    end

    def self.start_supervisor(config, options={}, &)
      run_options = {}
      run_options[:respawn] = options[:respawn]
      run_options[:stop_when_none] = options[:stop_when_none]
      run_options[:proxy] = options[:proxy]
      run_options[:force_single_log] = options[:foreground]
      run_options[:port_allocations] = options[:port_allocations]

      tidy_pids(config)

      if options[:clean]
        FileUtils.rm_rf(Dir[File.join(config.pid_root, "*")])
        puts "Emptied PID directory"
      end

      if !Dir[File.join(config.pid_root, "*")].empty?
        raise Error, "The PID directory (#{config.pid_root}) is not empty. Cannot start unless things are clean."
      end

      $0="[procodile] #{config.app_name} (#{config.root})"
      if options[:foreground]
        File.write(config.supervisor_pid_path, ::Process.pid)
        Supervisor.new(config, run_options).start(&)
      else
        FileUtils.rm_f(File.join(config.pid_root, "*.pid"))
        pid = fork do
          STDOUT.reopen(config.log_path, "a")
          STDOUT.sync = true
          STDERR.reopen(config.log_path, "a")
          STDERR.sync = true
          Supervisor.new(config, run_options).start(&)
        end
        ::Process.detach(pid)
        File.write(config.supervisor_pid_path, pid)
        puts "Started Procodile supervisor with PID #{pid}"
      end
    end

    def self.tidy_pids(config)
      FileUtils.rm_f(config.supervisor_pid_path)
      FileUtils.rm_f(config.sock_path)
      pid_files = Dir[File.join(config.pid_root, "*.pid")]
      pid_files.each do |pid_path|
        file_name = pid_path.split("/").last
        pid = File.read(pid_path).to_i
        if self.pid_active?(pid)
          puts "Could not remove #{file_name} because process (#{pid}) was active"
        else
          FileUtils.rm_f(pid_path)
          puts "Removed #{file_name} because process was not active"
        end
      end
    end
  end
end
