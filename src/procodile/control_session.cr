module Procodile
  class ControlSession
    delegate process_manager, config, issue_tracker, to: @supervisor

    def initialize(@supervisor : Supervisor, @client : UNIXSocket)
    end

    private def start_processes(options : ControlSession::Options) : String
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

      "200 #{instances.map(&.to_struct).to_json}"
    end

    private def stop(options : ControlSession::Options) : String
      instances = @supervisor.stop(
        Supervisor::Options.new(
          process_names: options.process_names,
          stop_supervisor: options.stop_supervisor
        )
      )

      "200 #{instances.map(&.to_struct).to_json}"
    end

    private def restart(options : ControlSession::Options) : String
      instances = @supervisor.restart(
        Supervisor::Options.new(
          process_names: options.process_names,
          tag: options.tag
        )
      )

      "200 " + instances.map { |a| a.map { |i| i ? i.to_struct : nil } }.to_json
    end

    private def reload_config(options : ControlSession::Options) : String
      @supervisor.reload_config

      %(200 {"ok":true})
    end

    private def check_concurrency(options : ControlSession::Options) : String
      result = @supervisor.check_concurrency(
        Supervisor::Options.new(
          reload: options.reload
        )
      )

      result = result.transform_values { |instances, _type| instances.map(&.to_struct) }

      "200 #{result.to_json}"
    end

    private def status(options : ControlSession::Options) : String
      instances = {} of String => Array(Instance::Config)
      processes = [] of Procodile::Process
      seen_names = Set(String).new

      # 先使用配置文件初始化实例（可能是最新修改过的）
      config.processes.each do |_, process|
        instances[process.name] = [] of Instance::Config
        processes << process
        seen_names << process.name
      end

      # 使用目前实际存在的替换空列表（可能配置文件已经移除，但是仍在运行）
      @supervisor.processes.each do |process, process_instances|
        instances[process.name] = process_instances.map(&.to_struct)
        processes << process unless seen_names.includes?(process.name)
      end

      processes = processes.map(&.to_struct)

      loaded_at = config.loaded_at

      result = ControlClient::ReplyOfStatusCommand.new(
        version: VERSION,
        messages: process_manager.messages,
        root: config.root,
        app_name: config.app_name,
        supervisor: @supervisor.to_hash,
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

      "200 #{result.to_json}"
    end

    def receive_data(data : String) : String
      command, session_data = data.split(/\s+/, 2)
      options = ControlSession::Options.from_json(session_data)

      case command
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
        "404 Invalid command"
      end
    rescue e : Error
      Procodile.log "control", "Error: #{e.message}".colorize.red.to_s
      "500 #{e.message}"
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
