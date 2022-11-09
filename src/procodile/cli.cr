require "./config"
require "./control_client"
require "./commands/help_command"
require "./commands/kill_command"
require "./commands/start_command"
require "./version"

module Procodile
  class CLI
    COMMANDS = [
      {:help, "Shows this help output"},
      {:kill, "Forcefully kill all known processes"},
      {:start, "Starts processes and/or the supervisor"},
    ]

    property options, config

    def self.commands : Hash(String, CliCommand)
      @@commands ||= {} of String => CliCommand
    end

    def self.options(&block : Proc(OptionParser, Procodile::CLI, Nil)) : Nil
      @@options = block
    end

    {% begin %}
      {% for e in COMMANDS %}
        {% name = e[0] %}
        include {{ (name.camelcase + "Command").id }}
      {% end %}

        def initialize
          @options = Procodile::CliOptions.new
          @config = uninitialized Procodile::Config

          {% for e in COMMANDS %}
            {% name = e[0] %}
            {% description = e[1] %}

            self.class.commands[{{ name.id.stringify }}] = CliCommand.new(
              name: {{ name.id.stringify }},
              description: {{ description.id.stringify }},
              options: @@options,
              callable: ->{{ name.id }}
            )
          {% end %}
        end
    {% end %}

    def dispatch(command) : Nil
      if self.class.commands.has_key?(command)
        self.class.commands[command].callable.as(Proc(Nil)).call
      else
        raise Error.new("Invalid command '#{command}'")
      end
    end

    def self.pid_active?(pid) : Bool
      ::Process.pgid(pid) ? true : false
    rescue RuntimeError
      false
    end

    def self.start_supervisor(config : Procodile::Config, options = Procodile::CliOptions.new, &block : Proc(Procodile::Supervisor, Nil)) : Nil
      run_options = Procodile::RunOptions.new
      run_options.respawn = options.respawn
      run_options.stop_when_none = options.stop_when_none
      run_options.proxy = options.proxy
      run_options.force_single_log = options.foreground
      run_options.port_allocations = options.port_allocations

      tidy_pids(config)

      if options.clean
        FileUtils.rm_rf(Dir[File.join(config.pid_root, "*")])
        puts "Emptied PID directory"
      end

      if !Dir[File.join(config.pid_root, "*")].empty?
        raise Error.new "The PID directory (#{config.pid_root}) is not empty. Cannot start unless things are clean."
      end

      # PROGRAM_NAME = "[procodile] #{config.app_name} (#{config.root})"
      if options.foreground
        File.write(config.supervisor_pid_path, ::Process.pid)
        Supervisor.new(config, run_options).start(block)
      else
        FileUtils.rm_rf(File.join(config.pid_root, "*.pid"))
        process = ::Process.fork do
          log_path = File.open(config.log_path, "a")
          STDOUT.reopen(log_path); STDOUT.sync = true
          STDERR.reopen(log_path); STDERR.sync = true
          Supervisor.new(config, run_options).start(block)
        end
        spawn { process.wait }
        pid = process.pid
        File.write(config.supervisor_pid_path, pid)
        puts "Started Procodile supervisor with PID #{pid}"
      end
    end

    def self.tidy_pids(config : Procodile::Config) : Nil
      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(config.sock_path)

      pid_files = Dir[File.join(config.pid_root, "*.pid")]
      pid_files.each do |pid_path|
        file_name = pid_path.split("/").last
        pid = File.read(pid_path).to_i
        if self.pid_active?(pid)
          puts "Could not remove #{file_name} because process (#{pid}) was active"
        else
          FileUtils.rm_rf(pid_path)
          puts "Removed #{file_name} because process was not active"
        end
      end
    end

    private def supervisor_running? : Bool
      if pid = current_pid
        self.class.pid_active?(pid)
      else
        false
      end
    end

    private def current_pid : Int64?
      if File.exists?(@config.supervisor_pid_path)
        pid_file = File.read(@config.supervisor_pid_path).strip
        pid_file.empty? ? nil : pid_file.to_i64
      end
    end

    private def process_names_from_cli_option : Array(String)?
      _processes = @options.processes

      if _processes
        processes = _processes.split(",")

        raise Error.new "No process names provided" if processes.empty?

        # processes.each do |process|
        #  process_name, _ = process.split('.', 2)
        #  unless @config.process_list.keys.includes?(process_name.to_s)
        #    raise Error.new "Process '#{process_name}' is not configured. You may need to reload your config."
        #  end
        # end

        processes
      end
    end
  end
end
