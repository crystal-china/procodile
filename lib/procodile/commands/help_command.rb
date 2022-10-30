module Procodile
  class CLI
    module HelpCommand
      def help
        puts "\e[45;37mWelcome to Procodile v#{Procodile::VERSION}\e[0m"
        puts "For documentation see https://adam.ac/procodile."
        puts

        puts "The following commands are supported:"
        puts
        self.class.commands.sort_by { |k, v| k.to_s }.each do |method, options|
          if options[:description]
            puts "  \e[34m#{method.to_s.ljust(18, ' ')}\e[0m #{options[:description]}"
          end
        end
        puts
        puts "For details for the options available for each command, use the --help option."
        puts "For example 'procodile start --help'."
      end

      def self.included(base)
        base.class_eval do
          command :help, "Shows this help output", self.instance_method(:help)
        end
      end
    end
  end
end
