require "./app_determination"
require "./config"
require "./commands/*"

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

        def initialize
          @config = uninitialized Config
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
        begin
          self.class.commands[command].callable.call
        ensure
          print_runtime_issues if command != "help" && supervisor_running?
        end
      else
        raise Error.new("Invalid command `#{command}', run `procodile help' for supported commands.".colorize.red.to_s)
      end
    end

    private def print_runtime_issues : Nil
      status = ControlClient.run(
        @config.sock_path, "status"
      ).as ControlClient::ReplyOfStatusCommand

      return if status.runtime_issues.empty?

      STDERR.puts "Active issues:".colorize.red
      status.runtime_issues.each do |issue|
        STDERR.puts " - #{issue.message}".colorize.red
      end
      STDERR.puts
    rescue ex : Error | Socket::Error | IO::Error
      # Do not block the actual command if issue reporting fails.
    end

    # 新增：检查 control socket 是否可连接（带短暂等待，避免启动竞态）
    private def control_socket_ready?(timeout : Time::Span = 300.milliseconds, interval : Time::Span = 25.milliseconds) : Bool
      sock_path = @config.sock_path
      deadline = Time.instant + timeout

      while Time.instant < deadline
        begin
          # 文件不存在就没必要 connect
          next sleep interval unless File.exists?(sock_path)

          UNIXSocket.new(sock_path).close
          return true
        rescue ex : File::Error
          # 文件刚出现/消失，继续等一下
        rescue ex : Socket::ConnectError
          # 文件存在但 server 还没 listen 完，继续等一下
        end

        sleep interval
      end

      false
    end

    private def supervisor_running? : Bool
      pid_path = @config.supervisor_pid_path

      return false unless File.exists?(pid_path)

      pid = File.read(pid_path).strip

      return false if pid.blank?

      return false unless ::Process.exists?(pid.to_i64)

      # 当前实现，这个检测其实是非必须的。
      control_socket_ready?
    end

    private def process_names_from_cli_option : Array(String)?
      _processes = @options.processes

      if _processes
        processes = _processes.split(",").uniq!

        raise Error.new "No process names provided" if processes.empty?

        @config.reload

        processes.each do |process|
          process_name = process.split('.', 2).first

          if !@config.processes.has_key?(process_name.to_s)
            raise Error.new "Unknown process '#{process_name}'."
          end
        end

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
      property env_file : String?
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
