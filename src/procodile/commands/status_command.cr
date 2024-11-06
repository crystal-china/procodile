require "../status_cli_output"
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

      def status : Nil
        if supervisor_running?
          status = ControlClient.run(@config.sock_path, "status").as ControlClient::ReplyOfStatusCommand

          if @options.json
            puts status.to_json
          elsif @options.json_pretty
            puts status
            nil
          elsif @options.simple
            if status.messages.empty?
              message = status.instances.map { |p, i| "#{p}[#{i.size}]" }
              
              puts "OK || #{message.join(", ")}"
            else
              message = status.messages.map { |p| Message.parse(p) }.join(", ")
              puts "Issues || #{message}"
            end
          else
            StatusCLIOutput.new(status).print_all
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
