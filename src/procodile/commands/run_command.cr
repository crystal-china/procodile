module Procodile
  class CLI
    module RunCommand
      OPTIONS = ->(_opts : OptionParser, _cli : CLI) do
      end

      private def run(command : String? = nil) : Nil
        exec(command)
      end
    end
  end
end
