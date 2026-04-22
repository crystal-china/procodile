module Procodile
  class CLI
    module ConsoleCommand
      OPTIONS = ->(_opts : OptionParser, _cli : CLI) do
      end

      private def console : Nil
        if (cmd = @config.console_command)
          exec(cmd)
        else
          raise Error.new "No console command has been configured in the Procfile"
        end
      end
    end
  end
end
