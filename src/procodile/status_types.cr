module Procodile
  # Represents a generic successful control command response.
  struct OkResponse
    include JSON::Serializable

    getter ok : Bool

    def initialize(@ok : Bool)
    end
  end

  # Represents the response from `start_processes`.
  struct StartProcessesResponse
    include JSON::Serializable

    getter started_instances : Array(Instance::Config)

    def initialize(@started_instances : Array(Instance::Config))
    end
  end

  # Represents the response from `stop`.
  struct StopProcessesResponse
    include JSON::Serializable

    getter stopped_instances : Array(Instance::Config)

    def initialize(@stopped_instances : Array(Instance::Config))
    end
  end

  # Represents one instance-level change returned by `restart`.
  struct RestartChange
    include JSON::Serializable

    getter previous_instance : Instance::Config?
    getter current_instance : Instance::Config?

    def initialize(
      @previous_instance : Instance::Config?,
      @current_instance : Instance::Config?,
    )
    end
  end

  # Represents the response from `restart`.
  struct RestartProcessesResponse
    include JSON::Serializable

    getter changes : Array(RestartChange)

    def initialize(@changes : Array(RestartChange))
    end
  end

  # Represents the response from `check_concurrency`.
  struct CheckConcurrencyResponse
    include JSON::Serializable

    getter started_instances : Array(Instance::Config)
    getter stopped_instances : Array(Instance::Config)

    def initialize(
      @started_instances : Array(Instance::Config),
      @stopped_instances : Array(Instance::Config),
    )
    end
  end

  # Represents one configured process in `procodile status`.
  struct ProcessStatus
    include JSON::Serializable

    getter name : String
    getter schedule : String?
    getter random_delay : Int32
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
      @random_delay : Int32,
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

  # Represents the supervisor itself in `procodile status`.
  struct SupervisorStatus
    include JSON::Serializable

    getter started_at : Int64?
    getter pid : Int64
    getter proxy_enabled : Bool

    def initialize(
      @started_at : Int64?,
      @pid : Int64,
      @proxy_enabled : Bool,
    )
    end
  end

  # Represents the full payload returned by the `status` control command.
  struct StatusReply
    include JSON::Serializable

    getter version : String
    getter messages : Array(ProcessManager::Message)
    getter root : String
    getter app_name : String
    getter supervisor : SupervisorStatus
    getter instances : Hash(String, Array(Instance::Config))
    getter processes : Array(ProcessStatus)
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
      @supervisor : SupervisorStatus,
      @instances : Hash(String, Array(Instance::Config)),
      @processes : Array(ProcessStatus),
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
