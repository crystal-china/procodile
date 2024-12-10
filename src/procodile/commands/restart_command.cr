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
        if supervisor_running?
          instance_configs = ControlClient.run(
            @config.sock_path,
            "restart",
            processes: process_names_from_cli_option,
            tag: @options.tag,
          ).as Array(Tuple(Instance::Config?, Instance::Config?))

          if instance_configs.empty?
            puts "There are no processes to restart."
          else
            if instance_configs.first.to_a.compact[0].foreground?
              puts "WARNING: Using the restart command in foreground mode \
tends to be prone to failure, use it with caution."
            end

            instance_configs.each do |old_instance, new_instance|
              if old_instance && new_instance
                if old_instance.description == new_instance.description
                  puts "#{"Restarted".colorize.magenta} #{old_instance.description}"
                else
                  puts "#{"Restarted".colorize.magenta} #{old_instance.description} -> #{new_instance.description}"
                end
              elsif old_instance
                puts "#{"Stopped".colorize.red} #{old_instance.description}"
              elsif new_instance
                puts "#{"Started".colorize.green} #{new_instance.description}"
              end

              STDOUT.flush
            end
          end
        else
          raise Error.new "Procodile supervisor isn't running"
        end
      end
    end
  end
end
