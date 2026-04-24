require "./requires"
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

  # 把当前 ARGV 里的内容复制一份，以后就算 ARGV 自己被 OptionParser 改了、clear 了、shift 了
  # ORIGINAL_ARGV 这份快照也不变
  ORIGINAL_ARGV = ARGV.dup
  cli = CLI.new
  command, valid_command, _probe_argv = probe_command(ORIGINAL_ARGV, cli)
  options, remaining_args = parse_options(valid_command, cli)

  command_args = if valid_command && remaining_args.size > 1
                   remaining_args[1..]
                 else
                   [] of String
                 end

  cli.options.command_args = command_args

  global_config = load_global_config
  ap = if command_requires_app?(valid_command)
         determine_app(FileUtils.pwd, options, global_config)
       end

  begin
    configure_cli_for_command(cli, ap, valid_command, command_args)
    cli.dispatch(command || "help")
  rescue ex : Error
    abort "Error: #{ex.message}".colorize.red
  end

  private def self.probe_command(original_argv : Array(String), cli : CLI) : Tuple(String?, CLI::Command?, Array(String))
    probe_argv = original_argv.dup

    OptionParser.parse(probe_argv) do |opt|
      opt.on("-r", "--root PATH", "The path to the root of your application") { }
      opt.on("--procfile PATH", "The path to the Procfile (defaults to: Procfile)") { }
      opt.on("-h", "--help", "Show this help message and exit") { }
      opt.on("-v", "--version", "Show version") { }

      # 默认行为是，存在 invalid option （- 开头的）会炸，例如，当我传递一个子命令选项
      # 但是我这里并没有编写 opt 处理它
      opt.invalid_option { }

      opt.unknown_args do |args|
        probe_argv = args
      end
    end

    command = probe_argv[0]?
    valid_command = cli.class.commands[command]?

    {command, valid_command, probe_argv}
  end

  private def self.parse_options(valid_command : CLI::Command?, cli : CLI) : Tuple(Hash(Symbol, String), Array(String))
    options = {} of Symbol => String
    remaining_args = [] of String

    OptionParser.parse do |opt|
      # 执行 parse 后，在这里会更新 opt 输出以及 cli.options
      if valid_command && (option_proc = valid_command.options)
        option_proc.call(opt, cli)
      end

      if valid_command
        opt.banner = "Usage: procodile #{valid_command.name} [options]\n"
      else
        opt.banner = "Usage: procodile command [options]"
      end

      opt.separator
      opt.separator("Global options (can be used before or after the subcommand):\n")

      opt.on("-r", "--root PATH", "The path to the root of your application") do |root|
        options[:root] = root
      end

      opt.on("--procfile PATH", "The path to the Procfile (default: Procfile)") do |path|
        options[:procfile] = path
      end

      opt.on("-h", "--help", "Show this help message and exit") do
        STDERR.puts opt

        exit 0 if valid_command
      end

      opt.on("-v", "--version", "Show the version and exit\n") do
        abort VERSION, status: 0
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

    {options, remaining_args}
  end

  private def self.load_global_config : Array(Config::GlobalOption)
    global_config_path = ENV["PROCODILE_CONFIG"]? || "/etc/procodile"

    if File.file?(global_config_path)
      global_config_yaml = File.read(global_config_path)
      global_config_node = YAML.parse(global_config_yaml)

      if global_config_node.raw.is_a?(Array)
        Array(Config::GlobalOption).from_yaml(global_config_yaml)
      elsif global_config_node.raw.is_a?(Hash)
        [Config::GlobalOption.from_yaml(global_config_yaml)]
      else
        raise Error.new("Invalid global configuration format in #{global_config_path}")
      end
    else
      [] of Config::GlobalOption
    end
  end

  private def self.determine_app(pwd : String, options : Hash(Symbol, String), global_config : Array(Config::GlobalOption)) : AppDetermination
    # Create a determination to work out where we want to load our app from
    ap = AppDetermination.new(
      pwd,
      options[:root]?,
             options[:procfile]?,
             global_config
    )

    if ap.ambiguous?
      if (app_id = ENV["PROCODILE_APP_ID"]?)
        ap.set_app_id_and_find_root_and_procfile(app_id.to_i)
      elsif ap.app_options.empty?
        abort "Error: Could not find Procfile in #{pwd}/Procfile".colorize.red
      else
        puts "There are multiple applications configured in #{ENV["PROCODILE_CONFIG"]? || "/etc/
             procodile"}"
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
            abort "Invalid app number: #{app_id + 1}"
          end
        end
      end
    end

    ap
  end

  private def self.command_requires_app?(valid_command : CLI::Command?) : Bool
    !!(valid_command && valid_command.name != "help")
  end

  private def self.configure_cli_for_command(cli : CLI, ap : AppDetermination?, valid_command : CLI::Command?, command_args : Array(String)) : Nil
    if valid_command && valid_command.name.in?({"start", "restart", "stop"}) && command_args.any?
      raise Error.new "Invalid argument(s) for `#{valid_command.name}`: #{command_args.join(" ")}. Use `-p/--processes` to target processes."
    end

    return unless command_requires_app?(valid_command)

    resolved_app = ap.not_nil!
    cli.config = Config.new(resolved_app.root || "", resolved_app.procfile)
    user = cli.config.user

    if user && user != ENV["USER"]
      STDERR.puts "Procodile must be run as #{user}. Re-executing as #{user}...".colorize.red

      exe = ::Process.executable_path || $0

      ::Process.exec(
        "sudo",
        ["-H", "-u", user, "--", exe] + ORIGINAL_ARGV
      )
    end
  end

  private def self.root : String
    File.expand_path("..", __DIR__)
  end

  private def self.bin_path : String
    File.join(root, "bin", "procodile")
  end
end
