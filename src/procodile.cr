require "./requires"
require "./procodile/version"
require "./procodile/cli"
require "./procodile/cli_parser"

module Procodile
  class Error < Exception
  end

  ORIGINAL_ARGV = ARGV.dup

  def self.run
    # 把当前 ARGV 里的内容复制一份，以后就算 ARGV 自己被 OptionParser 改了、clear 了、shift 了
    # ORIGINAL_ARGV 这份快照也不变
    cli = CLI.new
    invocation = parse_invocation(ORIGINAL_ARGV, cli)
    cli.options.extra_args = invocation.extra_args
    global_config = load_global_config
    ap = if command_requires_app?(invocation.valid_command)
           determine_app(FileUtils.pwd, invocation.options, global_config)
         end

    begin
      valid_command = invocation.valid_command
      extra_args = invocation.extra_args

      if valid_command && valid_command.name.in?({"start", "restart", "stop"}) && extra_args.any?
        raise Error.new "Invalid argument(s) for `#{valid_command.name}`: #{extra_args.join(" ")}. \
Use `-p/--processes` to target processes."
      end

      prepare_command_execution(cli, ap, valid_command)
      cli.dispatch(invocation.command || "help")
    rescue ex : Error
      abort "Error: #{ex.message}".colorize.red
    end
  end

  run

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
        choose_application(ap)
      end
    end

    ap
  end

  private def self.command_requires_app?(valid_command : CLI::Command?) : Bool
    !!(valid_command && valid_command.name != "help")
  end

  private def self.choose_application(ap : AppDetermination) : Nil
    puts "There are multiple applications configured in #{ENV["PROCODILE_CONFIG"]? || "/etc/procodile"}"
    puts "Choose an application:".colorize.light_gray.on_magenta

    ap.app_options.each do |i, app|
      col = i % 3
      print "#{(i + 1)}) #{app}"[0, 28].ljust(col != 2 ? 30 : 0, ' ')
      if col == 2 || i == ap.app_options.size - 1
        puts
      end
    end

    input = STDIN.gets

    return if input.nil?

    app_id = input.strip.to_i - 1

    if ap.app_options[app_id]?
      ap.set_app_id_and_find_root_and_procfile(app_id)
    else
      abort "Invalid app number: #{app_id + 1}"
    end
  end

  private def self.prepare_command_execution(cli : CLI, ap : AppDetermination?, valid_command : CLI::Command?) : Nil
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
end
