module Procodile
  class CLI
    module CheckConcurrencyCommand
      OPTIONS = ->(opts : OptionParser, cli : CLI) do
        opts.on(
          "--no-reload",
          "Do not reload the configuration before checking"
        ) do |_processes|
          cli.options.reload = false
        end
      end

      private def check_concurrency : Nil
        if supervisor_running?
          reply = ControlClient.check_concurrency(
            @config.sock_path,
            @options.reload?
          )

          if reply.started_instances.empty? && reply.stopped_instances.empty?
            puts "Processes are running as configured"
          else
            reply.started_instances.each do |instance|
              puts "#{"Started".colorize.green} #{instance.description} (PID: #{instance.pid})"
            end

            reply.stopped_instances.each do |instance|
              puts "#{"Stopped".colorize.red} #{instance.description} (PID: #{instance.pid})"
            end
          end
        else
          raise Error.new "Procodile supervisor isn't running"
        end
      end
    end
  end
end
