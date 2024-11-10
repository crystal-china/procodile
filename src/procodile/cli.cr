require "./config"
require "./control_client"
require "./commands/*"
require "./core_ext/process"
require "./version"

module Procodile
  class CLI
    COMMANDS = [
      {:help, "Shows this help output"},
      {:kill, "Forcefully kill all known processes"},
      {:start, "Starts processes and/or the supervisor"},
      {:stop, "Stops processes and/or the supervisor"},
      {:exec, "Execute a command within the environment"},
      {:run, "Execute a command within the environment"},
      {:reload, "Reload Procodile configuration"},
      {:check_concurrency, "Check process concurrency"},
      {:log, "Open/stream a Procodile log file"},
      {:restart, "Restart processes"},
      {:status, "Show the current status of processes"},
      {:console, "Open a console within the environment"},
    ]
    property options, config

    def self.commands : Hash(String, Command)
      @@commands ||= {} of String => Command
    end

    @@options = {} of Symbol => Proc(OptionParser, Procodile::CLI, Nil)

    def self.options(name, &block : Proc(OptionParser, Procodile::CLI, Nil))
      @@options[name] = block
    end

    {% begin %}
      {% for e in COMMANDS %}
        {% name = e[0] %}
        include {{ (name.camelcase + "Command").id }}
      {% end %}

        def initialize
          @options = Options.new
          @config = uninitialized Procodile::Config

          {% for e in COMMANDS %}
            {% name = e[0] %}
            {% description = e[1] %}

            self.class.commands[{{ name.id.stringify }}] = Command.new(
              name: {{ name.id.stringify }},
              description: {{ description.id.stringify }},
              options: @@options[{{ name }}],
              callable: ->{{ name.id }}
            )
          {% end %}
        end
    {% end %}

    def dispatch(command)
      if self.class.commands.has_key?(command)
        self.class.commands[command].callable.call
      else
        raise Error.new("Invalid command '#{command}'")
      end
    end

    def self.start_supervisor(
      config : Procodile::Config,
      options : Options = Options.new,
      &after_start : Proc(Procodile::Supervisor, Nil)
    )
      run_options = Supervisor::RunOptions.new(
        respawn: options.respawn,
        stop_when_none: options.stop_when_none,
        proxy: options.proxy,
        force_single_log: options.foreground,
        port_allocations: options.port_allocations,
        foreground: !!options.foreground
      )

      tidy_pids(config)

      if options.clean
        FileUtils.rm_rf(Dir[File.join(config.pid_root, "*")])
        puts "Emptied PID directory"
      end

      if !Dir[File.join(config.pid_root, "*")].empty?
        raise Error.new "The PID directory (#{config.pid_root}) is not empty. Cannot start unless things are clean."
      end

      # Set $PROGRAM_NAME in linux
      File.write("/proc/self/comm", "[procodile] #{config.app_name} (#{config.root})")

      if options.foreground
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
    def self.tidy_pids(config : Procodile::Config)
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

    private def supervisor_running? : Bool
      if File.exists?(@config.supervisor_pid_path)
        file_pid = File.read(@config.supervisor_pid_path).strip
        file_pid.empty? ? false : ::Process.exists?(file_pid.to_i64)
      else
        false
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

    struct Command
      getter name : String, description : String?, options : Proc(OptionParser, Procodile::CLI, Nil)?, callable : Proc(Nil)

      def initialize(@name, @description, @options, @callable)
      end
    end

    struct Options
      property foreground : Bool?
      property respawn : Bool?
      property stop_when_none : Bool?
      property proxy : Bool?
      property tag : String?
      property port_allocations : Hash(String, Int32)?
      property start_supervisor : Bool?
      property start_processes : Bool?
      property stop_supervisor : Bool?
      property wait_until_supervisor_stopped : Bool?
      property reload : Bool?
      property json : Bool?
      property json_pretty : Bool?
      property simple : Bool?
      property processes : String? # A String split by comma.
      property clean : Bool?
      property development : Bool?
      property wait : Bool?
      property lines : Int32?
      property process : String?

      def initialize
      end
    end
  end
end
