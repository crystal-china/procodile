require "yaml"
require "json"
require "../../src/procodile/cli"

module Procodile
  # TODO: 使用 class 重构，并且根据业务逻辑，指定 property 的默认值
  struct ProcessOption
    include YAML::Serializable

    property quantity : Int32?
    property restart_mode : Signal | String | Nil
    property max_respawns : Int32?
    property respawn_window : Int32?
    property log_path : String?
    property log_file_name : String?
    property term_signal : Signal?
    property allocate_port_from : Int32?
    property proxy_port : Int32?
    property proxy_address : String?
    property network_protocol : String?
    property env = {} of String => String

    def initialize
    end

    def merge(other : self?)
      new_process_option = self

      new_process_option.quantity = other.quantity if other.quantity
      new_process_option.restart_mode = other.restart_mode if other.restart_mode
      new_process_option.max_respawns = other.max_respawns if other.max_respawns
      new_process_option.respawn_window = other.respawn_window if other.respawn_window
      new_process_option.log_path = other.log_path if other.log_path
      new_process_option.log_file_name = other.log_file_name if other.log_file_name
      new_process_option.term_signal = other.term_signal if other.term_signal
      new_process_option.allocate_port_from = other.allocate_port_from if other.allocate_port_from
      new_process_option.proxy_port = other.proxy_port if other.proxy_port
      new_process_option.proxy_address = other.proxy_address if other.proxy_address
      new_process_option.network_protocol = other.network_protocol if other.network_protocol
      new_process_option.env = new_process_option.env.merge(other.env) if other.env

      new_process_option
    end
  end

  struct ProcfileOption
    include YAML::Serializable

    property app_name : String?
    property root : String?
    property procfile : String?
    property pid_root : String?
    property log_path : String?
    property log_root : String?
    property user : String?
    property console_command : String?
    property exec_prefix : String?
    property env : Hash(String, String)?
    property processes : Hash(String, ProcessOption)?

    def initialize
    end
  end

  record CliCommand,
    name : String,
    description : String?,
    options : Proc(OptionParser, Procodile::CLI, Nil)?,
    callable : Proc(Nil)

  struct CliOptions
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
    property processes : String?
    property clean : Bool?
    property development : Bool?
    property wait : Bool?
    property lines : Int32?
    property process : String?
  end

  struct RunOptions
    property respawn : Bool?
    property stop_when_none : Bool?
    property proxy : Bool?
    property force_single_log : Bool?
    property port_allocations : Hash(String, Int32)?
  end

  struct ControlClientReply
    include JSON::Serializable

    property description : String
    property pid : Int64
    property respawns : Int32
    property status : String
    property running : Bool
    property started_at : Int64
    property tag : String?
    property port : Int32?
  end

  struct ControlClientProcessStatus
    include JSON::Serializable

    property name : String
    property log_color : Int32
    property quantity : Int32
    property max_respawns : Int32
    property respawn_window : Int32
    property command : String
    property restart_mode : String
    property log_path : String?
    property removed : Bool
    property proxy_port : Int32?
    property proxy_address : String?
  end

  struct ControlClientReplyForStatusCommand
    include JSON::Serializable

    property version : String
    property messages : Array(String)
    property root : String
    property app_name : String
    property supervisor : NamedTuple(started_at: Int64, pid: Int64)
    property instances : Hash(String, Array(ControlClientReply))
    property processes : Array(ControlClientProcessStatus)
    property environment_variables : Hash(String, String)
    property procfile_path : String
    property option_path : String
    property local_option_path : String
    property sock_path : String
    property log_root : String?
    property supervisor_pid_path : String
    property pid_root : String
    property loaded_at : Int64
  end

  record SupervisorOptions,
    processes : Array(String)? = nil,
    stop_supervisor : Bool? = nil,
    tag : String? = nil
end
