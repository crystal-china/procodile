module Procodile
  class CLI
    module CheckConcurrencyCommand
      macro included
        options :check_concurrency do |opts, cli|
          opts.on("--no-reload", "Do not reload the configuration before checking") do |processes|
            cli.options.reload = false
          end
        end
      end

      def check_concurrency
        if supervisor_running?
          reply = ControlClient.run(
            @config.sock_path,
            "check_concurrency",
            {:reload => @options.reload}
          ).as(JSON::Any)

          if reply["started"].as_a.empty? && reply["stopped"].as_a.empty?
            puts "Processes are running as configured"
          else
            reply["started"].as_a.each do |instance|
              puts "Started".color(32) + " #{instance["description"]} (PID: #{instance["pid"]})"
            end

            reply["stopped"].as_a.each do |instance|
              puts "Stopped".color(31) + " #{instance["description"]} (PID: #{instance["pid"]})"
            end
          end
        else
          raise Error.new "Procodile supervisor isn't running"
        end
      end
    end
  end
end
