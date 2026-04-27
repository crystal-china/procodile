require "./requires"
require "./procodile/version"
require "./procodile/cli"
require "./procodile/cli_parser"
require "./procodile/app_resolution"

module Procodile
  class Error < Exception
  end

  ORIGINAL_ARGV = ARGV.dup

  def self.run
    # 把当前 ARGV 里的内容复制一份，以后就算 ARGV 自己被 OptionParser 改了、clear 了、shift 了
    # ORIGINAL_ARGV 这份快照也不变
    cli = CLI.new
    command, valid_command, options, extra_args = CLIParser.parse(ORIGINAL_ARGV, cli)
    cli.options.extra_args = extra_args

    begin
      if valid_command && valid_command.name.in?({"start", "restart", "stop"}) && extra_args.any?
        raise Error.new "Invalid argument(s) for `#{valid_command.name}`: #{extra_args.join(" ")}. \
Use `-p/--processes` to target processes."
      end

      if !!(valid_command && valid_command.name != "help")
        prepare_command_execution(cli, AppResolution.resolve(options))
      end

      cli.dispatch(command || "help")
    rescue ex : Error
      abort "Error: #{ex.message}".colorize.red
    end
  end

  run

  private def self.prepare_command_execution(cli : CLI, ap : AppDetermination) : Nil
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
