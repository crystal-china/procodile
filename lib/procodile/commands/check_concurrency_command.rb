module Procodile
  class CLI
    module CheckConcurrencyCommand
      def self.included(base)
        base.class_eval do
          options do |opts, cli|
            opts.on("--no-reload", "Do not reload the configuration before checking") do |processes|
              cli.options[:reload] = false
            end
          end

          def check_concurrency
            if supervisor_running?
              reply = ControlClient.run(@config.sock_path, "check_concurrency", :reload => @options[:reload])
              if reply["started"].empty? && reply["stopped"].empty?
                puts "Processes are running as configured"
              else
                reply["started"].each do |instance|
                  puts "Started".color(32) + " #{instance['description']} (PID: #{instance['pid']})"
                end

                reply["stopped"].each do |instance|
                  puts "Stopped".color(31) + " #{instance['description']} (PID: #{instance['pid']})"
                end
              end
            else
              raise Error, "Procodile supervisor isn't running"
            end
          end

          command :check_concurrency, "Check process concurrency"
        end
      end
    end
  end
end
