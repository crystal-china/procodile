module Procodile
  class CLI
    module HelpCommand
      macro included
        options :help do |opts, cli|
        end
      end

      private def help : Nil
        puts "Welcome to Procodile v#{VERSION}".colorize.light_gray.on_magenta
        puts "For documentation see https://adam.ac/procodile."
        puts

        puts "The following commands are supported:"
        puts

        self.class.commands.to_a.sort_by { |x| x[0] }.to_h.each do |method, options|
          if options.description
            puts "  #{method.to_s.ljust(18, ' ').colorize.blue} #{options.description}"
          end
        end

        puts
        puts "For details for the options available for each command, use the --help option."
        puts "For example 'procodile start --help'."
      end
    end
  end
end
