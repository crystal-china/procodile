module Procodile
  class CLI
    module ExecCommand
      macro included
        options :exec do |opts, cli|
        end
      end

      def exec(command : String? = nil) : Nil
        desired_command = command || ARGV[1..].join(" ")

        if (prefix = @config.exec_prefix)
          desired_command = "#{prefix} #{desired_command}"
        end

        if desired_command.empty?
          raise Error.new "You need to specify a command to run (e.g. procodile run -- rake db:migrate)"
        else
          environment = @config.environment_variables

          unless ENV["PROCODILE_EXEC_QUIET"]?.try(&.to_i) == 1
            puts "Running with #{desired_command.color(33)}"
            environment.each do |key, value|
              puts "             #{key.color(34)} #{value}"
            end
          end

          begin
            Dir.cd(@config.root)

            ::Process.exec(desired_command, env: environment, shell: true)
          rescue e : RuntimeError
            raise Error.new e.message
          end
        end
      end
    end
  end
end
