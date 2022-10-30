module Procodile
  class CLI
    module ReloadCommand
      def self.included(base)
        base.class_eval do
          def reload
            if supervisor_running?
              ControlClient.run(@config.sock_path, "reload_config")
              puts "Reloaded Procodile config"
            else
              raise Error, "Procodile supervisor isn't running"
            end
          end

          command :reload, "Reload Procodile configuration"
        end
      end
    end
  end
end
