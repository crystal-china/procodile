module Procodile
  class CLI
    module RunCommand
      macro included
        options :run do |opts, cli|
        end
      end

      private def run(command : String? = nil)
        exec(command)
      end
    end
  end
end
