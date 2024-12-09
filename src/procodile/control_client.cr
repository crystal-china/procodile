module Procodile
  class ControlClient
    alias SocketResponse = Array(Instance::Config) |
                           Array(Tuple(Instance::Config?, Instance::Config?)) |
                           NamedTuple(started: Array(Instance::Config), stopped: Array(Instance::Config)) |
                           ControlClient::ReplyOfStatusCommand | Bool

    def self.run(sock_path : String, command : String, **options) : SocketResponse
      socket = self.new(sock_path)
      socket.run(command, **options)
    ensure
      socket.try &.disconnect
    end

    def initialize(sock_path : String)
      @socket = UNIXSocket.new(sock_path)
    end

    def run(command : String, **options) : SocketResponse
      @socket.puts("#{command} #{options.to_json}")

      if (data = @socket.gets)
        code, reply = data.strip.split(/\s+/, 2)

        if code.to_i == 200 && reply && !reply.empty?
          case command
          when "start_processes", "stop"
            Array(Instance::Config).from_json(reply)
          when "restart"
            Array(Tuple(Instance::Config?, Instance::Config?)).from_json(reply)
          when "check_concurrency"
            NamedTuple(started: Array(Instance::Config), stopped: Array(Instance::Config)).from_json(reply)
          when "status"
            ControlClient::ReplyOfStatusCommand.from_json(reply)
          else # e.g. reload command
            true
          end
        else
          raise Error.new "Error from control server: #{code}: (#{reply.inspect})"
        end
      else
        raise Error.new "Control server disconnected. data: #{data.inspect}"
      end
    end

    def disconnect : Nil
      @socket.try &.close
    end

    struct ProcessStatus
      include JSON::Serializable

      getter name : String
      getter log_color : Colorize::ColorANSI
      getter quantity : Int32
      getter max_respawns : Int32
      getter respawn_window : Int32
      getter command : String
      getter restart_mode : Signal | String | Nil
      getter log_path : String?
      getter removed : Bool
      getter proxy_port : Int32?
      getter proxy_address : String?

      def initialize(
        @name : String,
        @log_color : Colorize::ColorANSI,
        @quantity : Int32,
        @max_respawns : Int32,
        @respawn_window : Int32,
        @command : String,
        @restart_mode : Signal | String | Nil,
        @log_path : String?,
        @removed : Bool,
        @proxy_port : Int32?,
        @proxy_address : String?,
      )
      end
    end
  end

  # Reply of `procodile status`
  struct ControlClient::ReplyOfStatusCommand
    include JSON::Serializable

    getter version : String
    getter messages : Array(Supervisor::Message)
    getter root : String
    getter app_name : String
    getter supervisor : NamedTuple(started_at: Int64?, pid: Int64)
    getter instances : Hash(String, Array(Instance::Config))
    getter processes : Array(ProcessStatus)
    getter environment_variables : Hash(String, String)
    getter procfile_path : String
    getter options_path : String
    getter local_options_path : String
    getter sock_path : String
    getter supervisor_pid_path : String
    getter pid_root : String
    getter loaded_at : Int64?
    getter log_root : String?

    def initialize(
      @version : String,
      @messages : Array(Supervisor::Message),
      @root : String,
      @app_name : String,
      @supervisor : NamedTuple(started_at: Int64?, pid: Int64),
      @instances : Hash(String, Array(Instance::Config)),
      @processes : Array(ProcessStatus),
      @environment_variables : Hash(String, String),
      @procfile_path : String,
      @options_path : String,
      @local_options_path : String,
      @sock_path : String,
      @supervisor_pid_path : String,
      @pid_root : String,
      @loaded_at : Int64?,
      @log_root : String?,
    )
    end
  end
end
