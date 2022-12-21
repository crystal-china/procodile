module Procodile
  class CLI
    module RunCommand
      macro included
        options :run do |opts, cli|
        end
      end

      def run(command = nil)
        exec(command)
      end
    end
  end
end
