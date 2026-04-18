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
        command_succeeded = false

        begin
          self.class.commands[command].callable.call
          command_succeeded = true
        ensure
          if command_succeeded && (command == "start" || (command != "help" && supervisor_running?))
            print_runtime_issues(command)
          end
        end
      else
        raise Error.new("Invalid command `#{command}', run `procodile help' for supported commands.".colorize.red.to_s)
      end
    end

    private def print_runtime_issues(command : String) : Nil
      status = case command
               when "start"
                 runtime_issue_status_reply(timeout: 5.seconds)
               when "stop", "restart", "reload", "check_concurrency"
                 runtime_issue_status_reply(timeout: 1.second)
               else
                 # status, log, help, console, run, exec
                 status_reply
               end

      return if status.runtime_issues.empty?

      STDERR.puts "Active issues:".colorize.red
      status.runtime_issues.each do |issue|
        STDERR.puts " - #{issue.message}".colorize.red
      end
      STDERR.puts
      STDERR.puts %(If a failing command needs shell features, try wrapping it explicitly, for example: `bash -lc "your-command arg1 arg2"`.).colorize.red
      STDERR.puts
    rescue ex : Error | Socket::Error | IO::Error
      # Do not block the actual command if issue reporting fails.
    end

    private def runtime_issue_status_reply(timeout : Time::Span, interval : Time::Span = 100.milliseconds) : ControlClient::ReplyOfStatusCommand
      deadline = Time.instant + timeout
      last_error = nil

      loop do
        begin
          return status_reply
        rescue ex : Error | Socket::Error | IO::Error
          last_error = ex
        end

        if Time.instant >= deadline
          raise last_error || Error.new("Timed out while waiting for runtime issues to become available.")
        end

        sleep interval
      end
    end

    # 新增：检查 control socket 是否可连接（带短暂等待，避免启动竞态）
    private def control_socket_ready?(*, timeout : Time::Span = 300.milliseconds, interval : Time::Span = 25.milliseconds) : Bool
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

      control_socket_ready?
    end

    private def process_names_from_cli_option : Array(String)?
      _processes = @options.processes

      if _processes
        processes = _processes.split(",").uniq!

        raise Error.new "No process names provided" if processes.empty?

        processes
      end
    end

    private def configured_process_names_from_cli_option : Array(String)?
      if (processes = process_names_from_cli_option)
        @config.reload

        processes.each do |process|
          process_name = process.split('.', 2).first

          if !@config.processes.has_key?(process_name.to_s)
            raise_unknown_or_removed_process_error(process_name.to_s)
          end
        end

        processes
      end
    end

    private def raise_unknown_or_removed_process_error(process_name : String) : NoReturn
      if supervisor_running?
        status = status_reply

        if status.processes.any? { |process| process.name == process_name && process.removed? }
          raise Error.new "Process '#{process_name}' has been removed from the Procfile and cannot be started or restarted. Run `procodile stop -p #{process_name}` to stop it."
        end
      end

      raise Error.new "Unknown process '#{process_name}'. A typo?"
    end

    # 被 restart 和 stop 调用，但是其实只有 stop 被传递的 process_names 可能包含 stopped process
    # 即：只有 stop 需要 compact_mapping, 不过，针对两个命令都额外去 nil 也没问题
    private def scheduled_processes_from_names(process_names : Array(String)?) : Array(Procodile::Process)
      return [] of Procodile::Process unless process_names

      process_names.compact_map do |name|
        process_name = name.split('.', 2).first
        process = @config.processes[process_name]?
        process if process && process.scheduled?
      end
    end

    private def status_reply : ControlClient::ReplyOfStatusCommand
      ControlClient.run(
        @config.sock_path, "status"
      ).as ControlClient::ReplyOfStatusCommand
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
      property command_args : Array(String)?
      property lines : Int32?
      property process : String?

      def initialize
      end
    end
  end
end
