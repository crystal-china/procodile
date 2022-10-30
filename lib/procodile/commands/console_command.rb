module Procodile
  class CLI
    module ConsoleCommand
      def self.included(base)
        base.class_eval do
          desc "Open a console within the environment"
          command def console
            if cmd = @config.console_command
              exec(cmd)
            else
              raise Error, "No console command has been configured in the Procfile"
            end
          end
        end
      end
    end
  end
end
