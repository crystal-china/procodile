module Procodile
  class CLI
    module RestartCommand
      macro included
        options :restart do |opts, cli|
          opts.on(
            "-p",
            "--processes a,b,c",
            "Only restart the listed processes or process types"
          ) do |processes|
            cli.options.processes = processes
          end

          opts.on(
            "-t",
            "--tag TAGNAME",
            "Tag all started processes with the given tag"
          ) do |tag|
            cli.options.tag = tag
          end
        end
      end

      private def restart : Nil
        raise Error.new "Procodile supervisor isn't running" unless supervisor_running?

        process_names = configured_process_names_from_cli_option
        removed_running_instances = [] of Instance::Config

        if !process_names # 如果是全量 restart
          status = status_reply

          status.processes.each do |process|
            next unless process.removed?

            removed_running_instances.concat(
              status.instances[process.name].select(&.status.running?)
            )
          end
        end

        instance_configs = ControlClient.run(
          @config.sock_path,
          "restart",
          processes: process_names,
          tag: @options.tag,
        ).as Array(Tuple(Instance::Config?, Instance::Config?))

        if instance_configs.empty?
          if process_names
            scheduled_processes = process_names.compact_map do |name|
              process_name = name.split('.', 2).first
              process = @config.processes[process_name]?
              process if process && process.scheduled?
            end

            if scheduled_processes.any?
              puts "Reloaded schedule for #{scheduled_processes.map(&.name).join(", ")}."

              return
            end
          end

          puts "There are no processes to restart."
        else
          #           if instance_configs.first.to_a.compact[0].foreground?
          #             puts "Caution: When using the restart command in foreground mode, \
          # tends to be prone to failure, use it with caution."
          #           end

          instance_configs.each do |old_instance, new_instance|
            if old_instance && new_instance
              if old_instance.description == new_instance.description
                puts "#{"Restarted".colorize.magenta} #{old_instance.description}"
              else
                puts "#{"Restarted".colorize.magenta} #{old_instance.description} \
-> #{new_instance.description}"
              end
            elsif old_instance
              puts "#{"Stopped".colorize.red} #{old_instance.description}"
            elsif new_instance
              puts "#{"Started".colorize.green} #{new_instance.description} (was not running)"
            end

            STDOUT.flush
          end
        end

        removed_running_instances.each do |instance|
          puts "#{"Skipped".colorize.yellow} #{instance.description}, it is still running but has been removed from the Procfile"
        end
      end
    end
  end
end
