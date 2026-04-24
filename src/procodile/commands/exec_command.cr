module Procodile
  class CLI
    module ExecCommand
      OPTIONS = ->(_opts : OptionParser, _cli : CLI) do
      end

      private def exec(command : String? = nil) : Nil
        desired_command = command || @options.command_args.try(&.join(" ")) || ""

        if (prefix = config.exec_prefix)
          desired_command = ([prefix, desired_command].join(" "))
        end

        if desired_command.empty?
          raise Error.new "You need to specify a command to run \
(e.g. procodile run -- rake db:migrate)"
        else
          environment = config.environment_variables

          unless ENV["PROCODILE_EXEC_QUIET"]?.try(&.to_i) == 1
            puts "Running with #{desired_command.colorize.yellow}"
            environment.each do |key, value|
              puts "             #{key.colorize.blue} #{value}"
            end
          end

          begin
            argv = ::Process.parse_arguments(desired_command)

            ::Process.exec(
              argv[0],
              argv[1..],
              env: environment,
              chdir: config.root
            )
          rescue e : RuntimeError
            raise Error.new e.message
          end
        end
      end
    end
  end
end
