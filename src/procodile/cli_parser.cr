module Procodile
  module CLIParser
    record ParsedInvocation,
      command : String?,
      valid_command : CLI::Command?,
      options : Hash(Symbol, String),
      extra_args : Array(String)

    def self.parse(original_argv : Array(String), cli : CLI) : ParsedInvocation
      options = {} of Symbol => String
      remaining_args = [] of String
      selected_command : CLI::Command? = nil
      argv = original_argv.dup

      parser = OptionParser.new do |opt|
        opt.banner = "Usage: procodile command [options]

Global options (can be used before or after the subcommand):"

        opt.on("-r", "--root PATH", "The path to the root of your application") do |root|
          options[:root] = root
        end

        opt.on("--procfile PATH", "The path to the Procfile (default: Procfile)") do |path|
          options[:procfile] = path
        end

        opt.on("-h", "--help", "Show this help message and exit") do
          abort opt, status: 0
        end

        opt.on("-v", "--version", "Show the version and exit\n") do
          abort VERSION, status: 0
        end

        CLI.commands.each do |command_name, command|
          opt.on(command_name, command.description) do
            selected_command = command
            opt.banner = "Usage: procodile #{command.name} [options]

Global options (can be used before or after the subcommand):"
            opt.separator("Subcommand options:")
            command.options.call(opt, cli)
          end
        end

        opt.invalid_option do |flag|
          abort "Invalid option: #{flag}\n\n#{opt}"
        end

        opt.missing_option do |flag|
          abort "Missing option for #{flag}\n\n#{opt}"
        end

        opt.unknown_args do |args|
          remaining_args = args
        end
      end

      parser.parse(argv)

      command = selected_command.try(&.name) || remaining_args[0]?
      extra_args = if selected_command
                     remaining_args
                   elsif remaining_args.size > 1
                     remaining_args[1..]
                   else
                     [] of String
                   end

      ParsedInvocation.new(
        command: command,
        valid_command: selected_command,
        options: options,
        extra_args: extra_args
      )
    end
  end
end
