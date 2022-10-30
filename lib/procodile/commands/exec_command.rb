module Procodile
  class CLI
    module ExecCommand
      def self.included(base)
        base.class_eval do
          def exec(command=nil)
            desired_command = command || ARGV.drop(1).join(" ")

            if prefix = @config.exec_prefix
              desired_command = "#{prefix} #{desired_command}"
            end

            if desired_command.empty?
              raise Error, "You need to specify a command to run (e.g. procodile run -- rake db:migrate)"
            else
              environment = @config.environment_variables

              unless ENV["PROCODILE_EXEC_QUIET"].to_i == 1
                puts "Running with #{desired_command.color(33)}"
                environment.each do |key, value|
                  puts "             #{key.color(34)} #{value}"
                end
              end

              begin
                Dir.chdir(@config.root)
                Rbenv.without do
                  Kernel.exec(environment, desired_command)
                end
              rescue Errno::ENOENT => e
                raise Error, e.message
              end
            end
          end

          alias run exec

          command :run, "Execute a command within the environment"
          command :exec, "Execute a command within the environment"
        end
      end
    end
  end
end
