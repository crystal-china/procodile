# require "procodile/status_cli_output"
require "../message"

module Procodile
  class CLI
    module StatusCommand
      macro included
        options :status do |opts, cli|
          opts.on("--json", "Return the status as a JSON hash") do
            cli.options.json = true
          end

          opts.on("--json-pretty", "Return the status as a JSON hash printed nicely") do
            cli.options.json_pretty = true
          end

          opts.on("--simple", "Return overall status") do
            cli.options.simple = true
          end
        end
      end

      def status
        if supervisor_running?
          status = ControlClient.run(@config.sock_path, "status")

          if @options.json
            puts status.to_json
          elsif @options.json_pretty
            # puts JSON.pretty_generate(status)
            pp! status
          elsif @options.simple
            _status = status.as(JSON::Any).as_h

            if _status["messages"].as_a.empty?
              message = _status["instances"].as_h.map { |p, i| "#{p}[#{i.size}]" }
              puts "OK || #{message.join(", ")}"
            else
              message = _status["messages"].as_a.map { |p| Message.parse(p) }.join(", ")
              puts "Issues || #{message}"
            end
          else
            # StatusCLIOutput.new(status).print_all
          end
        else
          if @options.simple
            puts "NotRunning || Procodile supervisor isn't running"
          else
            raise Error.new "Procodile supervisor isn't running"
          end
        end
      end
    end
  end
end
