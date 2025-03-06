require "./start_supervisor"
require "./control_client"
require "./commands/*"
require "./core_ext/process"

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
    property config : Config
    property options : Options = Options.new

    class_getter commands : Hash(String, Command) { {} of String => Command }

    @@options = {} of Symbol => Proc(OptionParser, CLI, Nil)

    {% begin %}
      {% for e in COMMANDS %}
        {% name = e[0] %}
        include {{ (name.camelcase + "Command").id }}
      {% end %}

        def initialize(@config : Config)
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

    def dispatch(command : String) : Nil
      if self.class.commands.has_key?(command)
        self.class.commands[command].callable.call
      else
        raise Error.new("Invalid command '#{command}'")
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

    private def self.options(name : Symbol, &block : Proc(OptionParser, CLI, Nil)) : Nil
      @@options[name] = block
    end

    struct Command
      getter name : String
      getter description : String
      getter options : Proc(OptionParser, CLI, Nil)
      getter callable : Proc(Nil)

      def initialize(
        @name : String,
        @description : String,
        @options : Proc(OptionParser, CLI, Nil),
        @callable : Proc(Nil),
      )
      end
    end

    struct Options
      property? foreground : Bool?
      property? respawn : Bool?
      property? stop_when_none : Bool?
      property? proxy : Bool?
      property? json : Bool?
      property? json_pretty : Bool?
      property? simple : Bool?
      property? clean : Bool?
      property? follow : Bool?
      property? start_supervisor : Bool?
      property? start_processes : Bool?
      property? stop_supervisor : Bool?
      property? wait_until_supervisor_stopped : Bool?
      property? reload : Bool?
      property tag : String?
      property port_allocations : Hash(String, Int32)?
      property processes : String? # A String split by comma.
      property lines : Int32?
      property process : String?

      def initialize
      end
    end
  end
end
