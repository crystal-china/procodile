require "yaml"
require "json"
require "../../src/procodile/cli"

module Procodile
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

  record(
    CliCommand,
    name : String,
    description : String?,
    options : Proc(OptionParser, Procodile::CLI, Nil)?,
    callable : Proc(Nil)
  )

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
    property processes : String? # A String split by comma.
    property clean : Bool?
    property development : Bool?
    property wait : Bool?
    property lines : Int32?
    property process : String?

    def initialize
    end
  end

  struct RunOptions
    property respawn : Bool?
    property stop_when_none : Bool?
    property? proxy = false
    property force_single_log : Bool?
    property port_allocations : Hash(String, Int32)?
  end

  record(
    ControlClientProcessStatus,
    name : String,
    log_color : Int32,
    quantity : Int32,
    max_respawns : Int32,
    respawn_window : Int32,
    command : String,
    restart_mode : Signal | String | Nil,
    log_path : String?,
    removed : Bool,
    proxy_port : Int32?,
    proxy_address : String?
  ) do
    include JSON::Serializable
  end
end
