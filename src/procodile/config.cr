require "./process"

module Procodile
  class Config
    COLORS = [
      Colorize::ColorANSI::Magenta, # 35 紫
      Colorize::ColorANSI::Red,     # 31 红
      Colorize::ColorANSI::Cyan,    # 36 青
      Colorize::ColorANSI::Green,   # 32 绿
      Colorize::ColorANSI::Yellow,  # 33 橘
      Colorize::ColorANSI::Blue,    # 34 蓝
    ]

    PROCFILE_SCHEDULE_SEPARATOR_REGEX = /__AT__/
    PROCFILE_SCHEDULE_ENTRY_REGEX     = /\A(.+?)(?:#{PROCFILE_SCHEDULE_SEPARATOR_REGEX})(.+)\z/

    getter procfile_entries : NamedTuple(commands: Hash(String, String), schedules: Hash(String, String?)) { parse_procfile_entries }
    getter process_list : Hash(String, String) { procfile_entries[:commands] }
    getter process_schedules : Hash(String, String?) { procfile_entries[:schedules] }
    getter processes : Hash(String, Procodile::Process) { {} of String => Procodile::Process }

    getter options : Config::Option { load_options_from_file }
    getter local_options : Config::Option { load_local_options_from_file }
    getter process_options : Hash(String, Procodile::Process::Option) do
      validate_process_option_keys(options.processes, options_path)
      options.processes || {} of String => Procodile::Process::Option
    end
    getter local_process_options : Hash(String, Procodile::Process::Option) do
      validate_process_option_keys(local_options.processes, local_options_path)
      local_options.processes || {} of String => Procodile::Process::Option
    end
    getter app_name : String do
      local_options.app_name || options.app_name || "Procodile"
    end
    getter loaded_at : Time?
    getter root : String
    getter environment_variables : Hash(String, String) do
      option_env = options.env || {} of String => String
      local_option_env = local_options.env || {} of String => String

      option_env.merge(local_option_env)
    end

    def initialize(@root : String, @procfile : String? = nil)
      unless File.file?(procfile_path)
        raise Error.new("Procfile not found at #{procfile_path}")
      end

      # We need to check to see if the local or options
      # configuration will override the root that we've been given.
      # If they do, we can throw away any reference to the one that the
      # configuration was initialized with and start using that immediately.
      if (new_root = local_options.root || options.root)
        @root = new_root
      end

      FileUtils.mkdir_p(pid_root)

      @processes = process_list.each_with_index.each_with_object(
        {} of String => Procodile::Process
      ) do |(h, index), hash|
        name = h[0]
        command = h[1]

        hash[name] = create_process(name, command, COLORS[index.divmod(COLORS.size)[1]])
      end

      @loaded_at = Time.local
    end

    def reload : Nil
      @options = nil
      @local_options = nil

      @process_options = nil
      @local_process_options = nil

      @procfile_entries = nil
      @process_list = nil
      @process_schedules = nil
      @environment_variables = nil
      @loaded_at = nil

      if (processes = @processes)
        process_list.each do |name, command|
          if (process = processes[name]?)
            process.removed = false

            # This command is already in our list. Add it.
            if process.command != command
              process.command = command

              Procodile.log "system", "#{name} command has changed. Updated."
            end

            process.options = options_for_process(name)
            process.schedule = schedule_for_process(name)
          else
            Procodile.log "system", "#{name} has been added to the Procfile. Adding it."

            processes[name] = create_process(name, command, COLORS[processes.size.divmod(COLORS.size)[1]])
          end
        end

        removed_processes_name = processes.keys - process_list.keys

        removed_processes_name.each do |process_name|
          if (p = processes[process_name])
            p.removed = true
            processes.delete(process_name)

            Procodile.log "system", "#{process_name} has been removed in the \
Procfile. It will be removed when it is stopped."
          end
        end
      end

      @loaded_at = Time.local
    end

    def user : String?
      local_options.user || options.user
    end

    def console_command : String?
      local_options.console_command || options.console_command
    end

    def exec_prefix : String?
      local_options.exec_prefix || options.exec_prefix
    end

    def options_for_process(name : String) : Procodile::Process::Option
      po = process_options[name]? || Procodile::Process::Option.new
      local_po = local_process_options[name]? || Procodile::Process::Option.new

      po.merge(local_po)
    end

    def pid_root : String?
      File.expand_path(local_options.pid_root || options.pid_root || "pids", self.root)
    end

    def supervisor_pid_path : String
      File.join(pid_root, "procodile.pid")
    end

    def log_path : String
      log_path = local_options.log_path || options.log_path

      if log_path
        File.expand_path(log_path, self.root)
      elsif log_path.nil? && (log_root = self.log_root)
        File.join(log_root, "procodile.log")
      else
        File.expand_path("procodile.log", self.root)
      end
    end

    def log_root : String?
      log_root = local_options.log_root || options.log_root

      File.expand_path(log_root, self.root) if log_root
    end

    def sock_path : String
      File.join(pid_root, "procodile.sock")
    end

    def procfile_path : String
      @procfile || File.join(self.root, "Procfile")
    end

    def options_path : String
      "#{procfile_path}.options"
    end

    def local_options_path : String
      "#{procfile_path}.local"
    end

    private def create_process(
      name : String,
      command : String,
      log_color : Colorize::ColorANSI,
    ) : Procodile::Process
      process = Procodile::Process.new(
        self,
        name,
        command,
        options_for_process(name),
        schedule_for_process(name)
      )
      process.log_color = log_color
      process
    end

    private def schedule_for_process(name : String) : String?
      options_schedule = options_for_process(name).at
      procfile_schedule = process_schedules[name]?

      if procfile_schedule && options_schedule
        Procodile.log(
          "system",
          "#{name} defines schedule in both Procfile and Procfile.options/.local; using options value #{options_schedule.inspect}"
        )
      end

      options_schedule || procfile_schedule
    end

    private def parse_procfile_entries : NamedTuple(commands: Hash(String, String), schedules: Hash(String, String?))
      content = File.read(procfile_path)

      if content.blank?
        raise Error.new "It looks like your Procfile doesn't have any contents.
Did you forget to add commands, or was it empty by mistake?"
      end

      raw_entries = Hash(String, String).from_yaml(content)
      commands = {} of String => String
      schedules = {} of String => String?

      raw_entries.each do |raw_name, command|
        name, schedule = parse_process_name_and_schedule(raw_name)
        existing_name = commands.keys.find { |key| key.compare(name, case_insensitive: true) == 0 }

        if existing_name
          raise Error.new("Duplicate process name '#{name}' in Procfile: \
conflicts with '#{existing_name}' (case-insensitively).")
        end

        commands[name] = command
        schedules[name] = schedule
      end

      {commands: commands, schedules: schedules}
    end

    private def parse_process_name_and_schedule(raw_name : String) : Tuple(String, String?)
      match = raw_name.match(PROCFILE_SCHEDULE_ENTRY_REGEX)

      if match
        {match[1], match[2].strip}
      else
        {raw_name, nil}
      end
    end

    private def load_options_from_file : Config::Option
      if File.exists?(options_path)
        Config::Option.from_yaml(File.read(options_path))
      else
        Config::Option.new
      end
    end

    private def load_local_options_from_file : Config::Option
      if File.exists?(local_options_path)
        Config::Option.from_yaml(File.read(local_options_path))
      else
        Config::Option.new
      end
    end

    private def validate_process_option_keys(
      process_options : Hash(String, Procodile::Process::Option)?,
      source_path : String,
    ) : Nil
      return unless process_options

      process_options.each_key do |name|
        if !process_list.has_key?(name)
          raise Error.new("Unknown process '#{name}' in #{source_path}.")
        end
      end
    end
  end

  struct Config::Option
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
    property processes : Hash(String, Procodile::Process::Option)?
    property app_id : Procodile::Process::Option?

    def initialize
    end
  end

  struct Config::GlobalOption
    include YAML::Serializable

    property name : String
    property root : String
    property procfile : String?
  end
end
