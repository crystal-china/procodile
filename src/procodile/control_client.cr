module Procodile
  class ControlClient
    def self.start_processes(
      sock_path : String,
      process_names : Array(String)? = nil,
      tag : String? = nil,
      port_allocations : Hash(String, Int32)? = nil,
    ) : Array(Instance::Config)
      request = ControlSession::Options.new(
        process_names: process_names,
        tag: tag,
        port_allocations: port_allocations
      )

      send_request(sock_path, "start_processes", request) do |reply|
        Array(Instance::Config).from_json(reply)
      end
    end

    def self.stop(
      sock_path : String,
      process_names : Array(String)? = nil,
      stop_supervisor : Bool? = nil,
    ) : Array(Instance::Config)
      request = ControlSession::Options.new(
        process_names: process_names,
        stop_supervisor: stop_supervisor
      )

      send_request(sock_path, "stop", request) do |reply|
        Array(Instance::Config).from_json(reply)
      end
    end

    def self.restart(
      sock_path : String,
      process_names : Array(String)? = nil,
      tag : String? = nil,
    ) : Array(Tuple(Instance::Config?, Instance::Config?))
      request = ControlSession::Options.new(
        process_names: process_names,
        tag: tag
      )

      send_request(sock_path, "restart", request) do |reply|
        Array(Tuple(Instance::Config?, Instance::Config?)).from_json(reply)
      end
    end

    def self.reload_config(sock_path : String) : Bool
      send_request(sock_path, "reload_config", ControlSession::Options.new) { true }
    end

    def self.check_concurrency(sock_path : String, reload : Bool? = nil) : NamedTuple(started: Array(Instance::Config), stopped: Array(Instance::Config))
      request = ControlSession::Options.new(reload: reload)

      send_request(sock_path, "check_concurrency", request) do |reply|
        NamedTuple(
          started: Array(Instance::Config),
          stopped: Array(Instance::Config)
        ).from_json(reply)
      end
    end

    def self.status(sock_path : String) : ControlClient::ReplyOfStatusCommand
      send_request(sock_path, "status", ControlSession::Options.new) do |reply|
        ControlClient::ReplyOfStatusCommand.from_json(reply)
      end
    end

    private def self.send_request(
                 sock_path : String,
                 command : String,
                 options, &decoder : String -> T
               ) : T forall T
      socket = UNIXSocket.new(sock_path)
      socket.puts("#{command} #{options.to_json}")

      if (data = socket.gets)
        code, reply = data.strip.split(/\s+/, 2)

        if code.to_i == 200 && reply
          decoder.call(reply)
        elsif code.to_i == 500 && reply
          message = begin
                      String.from_json(reply)
                    rescue JSON::ParseException
                      reply
                    end

          raise Error.new(message)
        else
          raise Error.new "Error from control server: #{code}: (#{reply.inspect})"
        end
      else
        raise Error.new "Control server disconnected. Check procodile.log for details."
      end
    ensure
      socket.try &.close
    end
  end

  struct ControlClient::ProcessStatus
    include JSON::Serializable

    getter name : String
    getter schedule : String?
    getter last_started_at : Int64?
    getter last_finished_at : Int64?
    getter last_exit_status : Int32?
    getter last_run_duration : Float64?
    getter log_color : Colorize::ColorANSI
    getter quantity : Int32
    getter max_respawns : Int32
    getter respawn_window : Int32
    getter command : String
    getter restart_mode : Signal | String | Nil
    getter log_path : String?
    getter? removed : Bool
    getter proxy_port : Int32?
    getter proxy_address : String?

    def initialize(
      @name : String,
      @schedule : String?,
      @last_started_at : Int64?,
      @last_finished_at : Int64?,
      @last_exit_status : Int32?,
      @last_run_duration : Float64?,
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

  # Reply of `procodile status`
  struct ControlClient::ReplyOfStatusCommand
    include JSON::Serializable

    getter version : String
    getter messages : Array(ProcessManager::Message)
    getter root : String
    getter app_name : String
    getter supervisor : NamedTuple(started_at: Int64?, pid: Int64, proxy_enabled: Bool)
    getter instances : Hash(String, Array(Instance::Config))
    getter processes : Array(ControlClient::ProcessStatus)
    getter runtime_issues : Array(IssueTracker::RuntimeIssue)
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
      @messages : Array(ProcessManager::Message),
      @root : String,
      @app_name : String,
      @supervisor : NamedTuple(started_at: Int64?, pid: Int64, proxy_enabled: Bool),
      @instances : Hash(String, Array(Instance::Config)),
      @processes : Array(ControlClient::ProcessStatus),
      @runtime_issues : Array(IssueTracker::RuntimeIssue),
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
