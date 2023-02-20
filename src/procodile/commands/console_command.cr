module Procodile
  class CLI
    module ConsoleCommand
      macro included
        options :console do |opts, cli|
        end
      end

      def console
        if (cmd = @config.console_command)
          exec(cmd)
        else
          raise Error.new "No console command has been configured in the Procfile"
        end
      end
    end
  end
end
