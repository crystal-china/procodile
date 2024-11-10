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
end
