module Procodile
  class CLI
    module ReloadCommand
      macro included
        options :reload do |opts, cli|
        end
      end

      private def reload : Nil
        if supervisor_running?
          ControlClient.reload_config(@config.sock_path)

          puts "Reloaded Procodile config"
        else
          raise Error.new "Procodile supervisor isn't running"
        end
      end
    end
  end
end
