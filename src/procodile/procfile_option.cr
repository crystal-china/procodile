require "yaml"
require "json"
require "../../src/procodile/cli"

module Procodile
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
    property processes : Hash(String, Process::Option)?
    property app_id : Process::Option?

    def initialize
    end
  end

  struct CliCommand
    getter name : String, description : String?, options : Proc(OptionParser, Procodile::CLI, Nil)?, callable : Proc(Nil)

    def initialize(@name, @description, @options, @callable)
    end
  end

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
end
