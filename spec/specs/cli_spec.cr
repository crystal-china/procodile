require "../spec_helper"
require "../../src/procodile/cli"

private def parse_command_options(
  cli : Procodile::CLI,
  command_name : String,
  args : Array(String),
) : Procodile::CLI::Options
  cli.options = Procodile::CLI::Options.new
  command = cli.class.commands[command_name]
  argv = args.dup

  OptionParser.parse(argv) do |opts|
    command.options.call(opts, cli)
  end

  cli.options
end

private def build_cli_with_config(config : Procodile::Config) : Procodile::CLI
  cli = Procodile::CLI.new
  cli.config = config
  cli
end

describe Procodile::CLI do
  context "an application with a Procfile" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "full"))

    it "registers the expected commands" do
      cli = build_cli_with_config(config)
      cli.class.commands.keys.sort.should eq(%w[
        check_concurrency
        console
        exec
        help
        kill
        log
        reload
        restart
        run
        start
        status
        stop
      ])
    end

    it "parses dev mode for start" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "start", ["--dev"])

      options.foreground?.should be_true
      options.proxy?.should be_true
      options.stop_when_none?.should be_true
      options.respawn?.should be_false
    end

    it "parses tag for start" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "start", ["--tag", "release-20260420"])

      options.tag.should eq("release-20260420")
    end

    it "parses tag for restart" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "restart", ["--tag", "release-20260420"])

      options.tag.should eq("release-20260420")
    end

    it "parses wait for stop" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "stop", ["--wait"])

      options.wait_until_supervisor_stopped?.should be_true
    end

    it "parses pretty JSON for status" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "status", ["--json-pretty"])

      options.json_pretty?.should be_true
    end

    it "parses no-reload for check_concurrency" do
      cli = build_cli_with_config(config)
      options = parse_command_options(cli, "check_concurrency", ["--no-reload"])

      options.reload?.should be_false
    end
  end
end
