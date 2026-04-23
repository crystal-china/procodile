require "./status_types"

module Procodile
  class ControlSession
    delegate process_manager, config, issue_tracker, to: @supervisor

    def initialize(@supervisor : Supervisor)
    end

    private def start_processes(options : ControlSession::Options) : Array(Instance::Config)
      if (ports = options.port_allocations)
        if (run_options_ports = @supervisor.run_options.port_allocations)
          run_options_ports.merge!(ports)
        else
          @supervisor.run_options.port_allocations = ports
        end
      end

      instances = @supervisor.start_processes(
        options.process_names,
        Supervisor::Options.new(tag: options.tag)
      )

      instances.map(&.to_struct)
    end

    private def stop(options : ControlSession::Options) : Array(Instance::Config)
      instances = @supervisor.stop(
        Supervisor::Options.new(
          process_names: options.process_names,
          stop_supervisor: options.stop_supervisor
        )
      )

      instances.map(&.to_struct)
    end

    private def restart(options : ControlSession::Options) : Array(Array(Instance::Config | Nil))
      instances = @supervisor.restart(
        Supervisor::Options.new(
          process_names: options.process_names,
          tag: options.tag
        )
      )

      instances.map { |pair| pair.map { |instance| instance ? instance.to_struct : nil } }
    end

    private def reload_config(options : ControlSession::Options) : NamedTuple(ok: Bool)
      @supervisor.reload_config

      {ok: true}
    end

    private def check_concurrency(options : ControlSession::Options) : Hash(Symbol, Array(Instance::Config))
      result = @supervisor.check_concurrency(
        Supervisor::Options.new(
          reload: options.reload
        )
      )

      result.transform_values { |instances, _type| instances.map(&.to_struct) }
    end

    private def status(options : ControlSession::Options) : StatusReply
      instances = {} of String => Array(Instance::Config)
      processes = [] of Procodile::Process
      seen_names = Set(String).new

      # 先使用配置文件初始化实例（可能是最新修改过的）
      config.processes.each do |_, process|
        instances[process.name] = [] of Instance::Config
        processes << process
        seen_names << process.name
      end

      # 合并正在运行但是配置中已经删除的实例
      @supervisor.processes.each do |process, process_instances|
        instances[process.name] = process_instances.map(&.to_struct)
        processes << process unless seen_names.includes?(process.name)
      end

      processes = processes.map(&.to_struct)

      loaded_at = config.loaded_at

      result = StatusReply.new(
        version: VERSION,
        messages: process_manager.messages,
        root: config.root,
        app_name: config.app_name,
        supervisor: @supervisor.to_status,
        instances: instances,
        processes: processes,
        runtime_issues: issue_tracker.runtime_issues,
        environment_variables: config.environment_variables,
        procfile_path: config.procfile_path,
        options_path: config.options_path,
        local_options_path: config.local_options_path,
        sock_path: config.sock_path,
        log_root: config.log_root,
        supervisor_pid_path: config.supervisor_pid_path,
        pid_root: config.pid_root,
        loaded_at: loaded_at ? loaded_at.to_unix : nil,
      )

      result
    end

    def receive_data(data : String) : String
      command, session_data = data.split(/\s+/, 2)
      options = ControlSession::Options.from_json(session_data)

      payload = case command
                when "start_processes"
                  start_processes(options)
                when "stop"
                  stop(options)
                when "restart"
                  restart(options)
                when "reload_config"
                  reload_config(options)
                when "check_concurrency"
                  check_concurrency(options)
                when "status"
                  status(options)
                else
                  return "404 Invalid command"
                end

      "200 #{payload.to_json}"
    rescue e : Error
      Procodile.log "control", "Error: #{e.message}".colorize.red.to_s
      "500 #{e.message || e.to_s}"
    end
  end

  struct ControlSession::Options
    include JSON::Serializable

    getter process_names : Array(String)?
    getter tag : String?
    getter port_allocations : Hash(String, Int32)?
    getter reload : Bool?
    getter stop_supervisor : Bool?

    def initialize(
      @process_names : Array(String)? = nil,
      @tag : String? = nil,
      @port_allocations : Hash(String, Int32)? = nil,
      @reload : Bool? = nil,
      @stop_supervisor : Bool? = nil,
    )
    end
  end
end
