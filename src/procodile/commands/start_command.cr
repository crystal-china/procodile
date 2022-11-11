module Procodile
  class CLI
    module StartCommand
      macro included
        options :start do |opts, cli|
          opts.on("-p", "--processes a,b,c", "Only start the listed processes or process types") do |processes|
            cli.options.processes = processes
          end

          opts.on("-t", "--tag TAGNAME", "Tag all started processes with the given tag") do |tag|
            cli.options.tag = tag
          end

          opts.on("--no-supervisor", "Do not start a supervisor if its not running") do
            cli.options.start_supervisor = false
          end

          opts.on("--no-processes", "Do not start any processes (only applicable when supervisor is stopped)") do
            cli.options.start_processes = false
          end

          opts.on("-f", "--foreground", "Run the supervisor in the foreground") do
            cli.options.foreground = true
          end

          opts.on("--clean", "Remove all previous pid and sock files before starting") do
            cli.options.clean = true
          end

          opts.on("--no-respawn", "Disable respawning for all processes") do
            cli.options.respawn = false
          end

          opts.on("--stop-when-none", "Stop the supervisor when all processes are stopped") do
            cli.options.stop_when_none = true
          end

          opts.on("-x", "--proxy", "Enables the Procodile proxy service") do
            cli.options.proxy = true
          end

          opts.on("--ports PROCESSES", "Choose ports to allocate to processes") do |processes|
            cli.options.port_allocations = processes.split(",").each_with_object({} of String => Int32) do |line, hash|
              process, port = line.split(":")
              hash[process] = port.to_i
            end
          end

          opts.on("-d", "--dev", "Run in development mode") do
            cli.options.development = true
            cli.options.respawn = false
            cli.options.foreground = true
            cli.options.stop_when_none = true
            cli.options.proxy = true
          end
        end
      end

      def start
        if supervisor_running?
          if @options.foreground
            raise Error.new "Cannot be started in the foreground because supervisor already running"
          end

          if @options.respawn
            raise Error.new "Cannot disable respawning because supervisor is already running"
          end

          if @options.stop_when_none
            raise Error.new "Cannot stop supervisor when none running because supervisor is already running"
          end

          if @options.proxy
            raise Error.new "Cannot enable the proxy when the supervisor is running"
          end

          instances = ControlClient.run(
            @config.sock_path,
            "start_processes",
            processes: process_names_from_cli_option,
            tag: @options.tag,
            port_allocations: @options.port_allocations,
          ).as Array(ControlClientReply)

          if !instances.empty?
            puts "No processes to start."
          else
            # [
            #     [0] {
            #         "description" => "test3.1",
            #                 "pid" => 552746,
            #            "respawns" => 0,
            #              "status" => "Running",
            #             "running" => true,
            #          "started_at" => 1667370102,
            #                 "tag" => nil,
            #                "port" => nil
            #     }
            # ]

            instances.each do |instance|
              puts "Started".color(32) + " #{instance.description} (PID: #{instance.pid})"
            end
          end
          nil
        else
          # The supervisor isn't actually running. We need to start it before processes can be
          # begin being processed
          if @options.start_supervisor == false
            raise Error.new "Supervisor is not running and cannot be started because --no-supervisor is set"
          else
            self.class.start_supervisor(@config, @options) do |supervisor|
              unless @options.start_processes == false
                supervisor.start_processes(
                  process_names_from_cli_option,
                  {tag: @options.tag}
                )
              end
            end
          end
        end
      end
    end
  end
end
