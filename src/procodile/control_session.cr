require "json"
require "./version"

module Procodile
  class ControlSession
    def initialize(@supervisor : Procodile::Supervisor, @client : UNIXSocket)
    end

    def start_processes(options) : String
      if options.port_allocations
        run_options_port_allocations = @supervisor.run_options.port_allocations
        if run_options_port_allocations
          run_options_port_allocations.merge!(options.port_allocations.not_nil!)
        else
          @supervisor.run_options.port_allocations = options.port_allocations
        end
      end

      instances = @supervisor.start_processes(
        options.processes,
        SupervisorOptions.new(tag: options.tag)
      )

      "200 #{instances.map(&.to_hash).to_json}"
    end

    def stop(options) : String
      instances = @supervisor.stop(
        SupervisorOptions.new(
          processes: options.processes,
          stop_supervisor: options.stop_supervisor
        )
      )

      "200 #{instances.map(&.to_hash).to_json}"
    end

    def restart(options) : String
      instances = @supervisor.restart(
        SupervisorOptions.new(
          processes: options.processes,
          tag: options.tag
        )
      )

      "200 " + instances.map { |a| a.map { |i| i ? i.to_hash : nil } }.to_json
    end

    def reload_config(options) : String
      @supervisor.reload_config

      "200 []"
    end

    def check_concurrency(options) : String
      result = @supervisor.check_concurrency(
        SupervisorOptions.new(
          reload: options.reload
        )
      )
      result = result.transform_values { |instances| instances.map(&.to_hash) }

      "200 #{result.to_json}"
    end

    def status(options) : String
      instances = {} of String => Array(Procodile::InstanceConfig)

      @supervisor.processes.each do |process, process_instances|
        instances[process.name] = [] of Procodile::InstanceConfig
        process_instances.each do |instance|
          instances[process.name] << instance.to_hash
        end
      end

      processes = @supervisor.processes.keys.map(&.to_hash)

      result = ControlClientReplyForStatusCommand.new(
        version: Procodile::VERSION,
        messages: @supervisor.messages,
        root: @supervisor.config.root,
        app_name: @supervisor.config.app_name,
        supervisor: @supervisor.to_hash,
        instances: instances,
        processes: processes,
        environment_variables: @supervisor.config.environment_variables,
        procfile_path: @supervisor.config.procfile_path,
        options_path: @supervisor.config.options_path,
        local_options_path: @supervisor.config.local_options_path,
        sock_path: @supervisor.config.sock_path,
        log_root: @supervisor.config.log_root,
        supervisor_pid_path: @supervisor.config.supervisor_pid_path,
        pid_root: @supervisor.config.pid_root,
        loaded_at: @supervisor.config.loaded_at.not_nil!.to_unix,
      )

      "200 #{result.to_json}"
    end

    {% begin %}
      def receive_data(data)
        command, _options = data.split(/\s+/, 2)
        options = ControlSessionData.from_json(_options)

        callable = {} of String => Proc(ControlSessionData, String)

        {% for e in @type.methods %}
          {% if e.name.stringify != "initialize" %}
            callable[{{ e.name.stringify }}] = ->{{ e.name }}(ControlSessionData)
          {% end %}
        {% end %}

        if callable[command]?
          begin
            callable[command].call(options)
          rescue e : Procodile::Error
            Procodile.log nil, "control", "Error: #{e.message}".color(31)
            "500 #{e.message}"
          end
        else
          "404 Invaid command"
        end
      end
    {% end %}
  end
end
