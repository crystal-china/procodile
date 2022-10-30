module Procodile
  class CLI
    module StatusCommand
      def self.included(base)
        base.class_eval do
          options do |opts, cli|
            opts.on("--json", "Return the status as a JSON hash") do
              cli.options[:json] = true
            end

            opts.on("--json-pretty", "Return the status as a JSON hash printed nicely") do
              cli.options[:json_pretty] = true
            end

            opts.on("--simple", "Return overall status") do
              cli.options[:simple] = true
            end
          end

          def status
            if supervisor_running?
              status = ControlClient.run(@config.sock_path, "status")
              if @options[:json]
                puts status.to_json
              elsif @options[:json_pretty]
                puts JSON.pretty_generate(status)
              elsif @options[:simple]
                if status["messages"].empty?
                  message = status["instances"].map { |p, i| "#{p}[#{i.size}]" }
                  puts "OK || #{message.join(', ')}"
                else
                  message = status["messages"].map { |p| Message.parse(p) }.join(", ")
                  puts "Issues || #{message}"
                end
              else
                require "procodile/status_cli_output"
                StatusCLIOutput.new(status).print_all
              end
            else
              if @options[:simple]
                puts "NotRunning || Procodile supervisor isn't running"
              else
                raise Error, "Procodile supervisor isn't running"
              end
            end
          end

          command :status, "Show the current status of processes"
        end
      end
    end
  end
end
