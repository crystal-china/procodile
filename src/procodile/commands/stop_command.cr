module Procodile
  class CLI
    module StopCommand
      macro included
        options :stop do |opts, cli|
          opts.on(
            "-p",
            "--processes a,b,c",
            "Only stop the listed processes or process types"
          ) do |processes|
            cli.options.processes = processes
          end

          opts.on(
            "-s",
            "--stop-supervisor",
            "Stop the supervisor process when all processes are stopped"
          ) do
            cli.options.stop_supervisor = true
          end

          opts.on(
            "--wait",
            "Wait until supervisor has stopped before exiting"
          ) do
            cli.options.wait_until_supervisor_stopped = true
          end
        end
      end

      private def stop : Nil
        raise Error.new "Procodile supervisor isn't running" unless supervisor_running?

        process_names = process_names_from_cli_option
        scheduled_processes = scheduled_processes_from_names(process_names)
        disabled_scheduling_message = "Future scheduling was disabled for \
#{scheduled_processes.map(&.name).join(", ")}."
        instances = ControlClient.run(
          @config.sock_path,
          "stop",
          processes: process_names,
          stop_supervisor: @options.stop_supervisor?,
        ).as(Array(Instance::Config))

        # 没有任何 Instance::Config 被 stop
        if instances.empty?
          if process_names
            if scheduled_processes.any?
              puts disabled_scheduling_message
            else
              suffix = process_names.size == 1 ? " '#{process_names.first}'" : "es"
              raise Error.new "No running process matches#{suffix}."
            end
          else
            puts "No processes were stopped."
          end
        else
          instances.each do |instance|
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
