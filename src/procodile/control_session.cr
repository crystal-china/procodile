module Procodile
  class ControlSession
    def initialize(@supervisor : Supervisor, @client : UNIXSocket)
    end

    private def start_processes(options : Options) : String
      if (ports = options.port_allocations)
        if (run_options_ports = @supervisor.run_options.port_allocations)
          run_options_ports.merge!(ports)
        else
          @supervisor.run_options.port_allocations = ports
        end
      end

      instances = @supervisor.start_processes(
        options.processes,
        Supervisor::Options.new(tag: options.tag)
      )

      "200 #{instances.map(&.to_struct).to_json}"
    end

    private def stop(options : Options) : String
      instances = @supervisor.stop(
        Supervisor::Options.new(
          processes: options.processes,
          stop_supervisor: options.stop_supervisor
        )
      )

      "200 #{instances.map(&.to_struct).to_json}"
    end

    private def restart(options : Options) : String
      instances = @supervisor.restart(
        Supervisor::Options.new(
          processes: options.processes,
          tag: options.tag
        )
      )

      "200 " + instances.map { |a| a.map { |i| i ? i.to_struct : nil } }.to_json
    end

    private def reload_config(options : Options) : String
      @supervisor.reload_config

      "200 []"
    end

    private def check_concurrency(options : Options) : String
      result = @supervisor.check_concurrency(
        Supervisor::Options.new(
          reload: options.reload
        )
      )

      result = result.transform_values { |instances, _type| instances.map(&.to_struct) }

      "200 #{result.to_json}"
    end

    private def status(options : Options) : String
      instances = {} of String => Array(Instance::Config)

      @supervisor.processes.each do |process, process_instances|
        instances[process.name] = [] of Instance::Config
        process_instances.each do |instance|
          instances[process.name] << instance.to_struct
        end
      end

      processes = @supervisor.processes.keys.map(&.to_struct)

      loaded_at = @supervisor.config.loaded_at

      result = ControlClient::ReplyOfStatusCommand.new(
        version: VERSION,
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
        loaded_at: loaded_at ? loaded_at.to_unix : nil,
      )

      "200 #{result.to_json}"
    end

    {% begin %}
      def receive_data(data : String) : String
        command, session_data = data.split(/\s+/, 2)
        options = Options.from_json(session_data)

        callable = {} of String => Proc(Options, String)

        {% for e in @type.methods %}
          # It's interest, @type.methods not include current defined #receive_data method.
          {% if e.name.stringify != "initialize" %}
            callable[{{ e.name.stringify }}] = ->{{ e.name }}(Options)
          {% end %}
        {% end %}

        if callable[command]?
          begin
            callable[command].call(options)
          rescue e : Error
            Procodile.log nil, "control", "Error: #{e.message}".colorize.red.to_s
            "500 #{e.message}"
          end
        else
          "404 Invaid command"
        end
      end
    {% end %}

    # Control session options
    struct Options
      include JSON::Serializable

      getter processes : Array(String)?
      getter tag : String?
      getter port_allocations : Hash(String, Int32)?
      getter reload : Bool?
      getter stop_supervisor : Bool?

      def initialize(
        @processes : Array(String)? = [] of String,
        @tag : String? = nil,
        @port_allocations : Hash(String, Int32)? = nil,
        @reload : Bool? = nil,
        @stop_supervisor : Bool? = nil,
      )
      end
    end
  end
end
