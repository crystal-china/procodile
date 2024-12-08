require "./requires"
require "./procodile/app_determination"
require "./procodile/cli"

module Procodile
  VERSION = {{
              `shards version "#{__DIR__}"`.chomp.stringify +
              " (rev " +
              `git rev-parse --short HEAD`.chomp.stringify +
              ")"
            }}

  class Error < Exception
  end

  private def self.root : String
    File.expand_path("..", __DIR__)
  end

  private def self.bin_path : String
    File.join(root, "bin", "procodile")
  end

  ORIGINAL_ARGV = ARGV.join(" ")
  command = ARGV[0]? || "help"
  options = {} of Symbol => String

  opt = OptionParser.new do |parser|
    parser.banner = "Usage: procodile #{command} [options]"

    parser.on("-r", "--root PATH", "The path to the root of your application") do |root|
      options[:root] = root
    end

    parser.on("--procfile PATH", "The path to the Procfile (defaults to: Procfile)") do |path|
      options[:procfile] = path
    end

    parser.on("-h", "--help", "Show this help message and exit") do
      STDOUT.puts parser
      exit 0
    end

    parser.on("-v", "--version", "Show version") do
      STDOUT.puts VERSION
      exit 0
    end

    parser.invalid_option do |flag|
      STDERR.puts "Invalid option: #{flag}.\n\n"
      STDERR.puts parser
      exit 1
    end

    parser.missing_option do |flag|
      STDERR.puts "Missing option for #{flag}\n\n"
      STDERR.puts parser
      exit 1
    end
  end

  # Get the global configuration file data
  global_config_path = ENV["PROCODILE_CONFIG"]? || "/etc/procodile"

  global_config = if File.file?(global_config_path)
                    Array(Config::GlobalOption).from_yaml(File.read(global_config_path))
                  else
                    [] of Config::GlobalOption
                  end

  # Create a determination to work out where we want to load our app from
  ap = AppDetermination.new(
    FileUtils.pwd,
    options[:root]?,
    options[:procfile]?,
    global_config
  )

  if ap.ambiguous?
    if (app_id = ENV["PROCODILE_APP_ID"]?)
      ap.set_app_id_and_find_root_and_procfile(app_id.to_i)
    elsif ap.app_options.empty?
      STDERR.puts "Error: Could not find Procfile in #{FileUtils.pwd}/Procfile".colorize.red
      exit 1
    else
      puts "There are multiple applications configured in #{global_config_path}"
      puts "Choose an application:".colorize.light_gray.on_magenta

      ap.app_options.each do |i, app|
        col = i % 3
        print "#{(i + 1)}) #{app}"[0, 28].ljust(col != 2 ? 30 : 0, ' ')
        if col == 2 || i == ap.app_options.size - 1
          puts
        end
      end

      input = STDIN.gets
      if !input.nil?
        app_id = input.strip.to_i - 1

        if ap.app_options[app_id]?
          ap.set_app_id_and_find_root_and_procfile(app_id)
        else
          puts "Invalid app number: #{app_id + 1}"
          exit 1
        end
      end
    end
  end

  begin
    cli = CLI.new
    cli.config = Config.new(ap.root || "", ap.procfile)

    if cli.class.commands[command]? && (option_proc = cli.class.commands[command].options)
      option_proc.call(opt, cli)
    end

    opt.parse

    #
    # For fix https://github.com/adamcooke/procodile/issues/30
    # Duplicate on this line is necessory for get new parsed ARGV.
    command = ARGV[0]? || "help"

    if command != "help"
      if cli.config.user && ENV["USER"] != cli.config.user
        STDERR.puts "Procodile must be run as #{cli.config.user}. Re-executing as #{cli.config.user}...".colorize.red

        ::Process.exec(
          command: "sudo -H -u #{cli.config.user} -- #{$0} #{ORIGINAL_ARGV}",
          shell: true
        )
      end
    end

    cli.dispatch(command)
  rescue ex : Error
    STDERR.puts "Error: #{ex.message}".colorize.red
    exit 1
  end
end
