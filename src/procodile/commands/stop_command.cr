module Procodile
  class CLI
    module StopCommand
      OPTIONS = ->(opts : OptionParser, cli : CLI) do
        opts.on(
          "-p",
          "--processes a,b,c",
          "Stop only the listed processes or process types"
        ) do |processes|
          cli.options.processes = processes
        end

        opts.on(
          "-s",
          "--stop-supervisor",
          "Stop the supervisor when all processes have stopped"
        ) do
          cli.options.stop_supervisor = true
        end

        opts.on(
          "--wait",
          "Wait until the supervisor has stopped before exiting"
        ) do
          cli.options.wait_until_supervisor_stopped = true
        end
      end

      private def stop : Nil
        raise Error.new "Procodile supervisor isn't running" unless supervisor_running?

        process_names = process_names_from_cli_option
        scheduled_processes = scheduled_processes_from_names(process_names)
        disabled_scheduling_message = "Future scheduling was disabled \
for #{scheduled_processes.map(&.name).join(", ")}."
        response = ControlClient.stop(
          config.sock_path,
          process_names,
          @options.stop_supervisor?,
        )

        if response.stopped_instances.empty?
          if process_names
            if scheduled_processes.any?
              puts disabled_scheduling_message
            else
              if process_names.size == 1
                raise Error.new "No running process matches '#{process_names.first}'."
              else
                raise Error.new "No running processes match: #{process_names.join(", ")}."
              end
            end
          else
            puts "No processes were stopped."
          end
        else
          response.stopped_instances.each do |instance|
            puts "#{"Stopped".colorize.red} #{instance.description} (PID: #{instance.pid})"
          end

          puts disabled_scheduling_message if scheduled_processes.any?
        end

        puts "Supervisor will be stopped when processes are stopped." if @options.stop_supervisor?

        if @options.wait_until_supervisor_stopped?
          puts "Waiting for supervisor to stop..."

          loop do
            sleep 1.second

            next if supervisor_running?

            abort "Supervisor has stopped", status: 0
          end
        end
      end
    end
  end
end
