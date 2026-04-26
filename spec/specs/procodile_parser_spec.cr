require "../spec_helper"

module Procodile
    def self.parse_invocation_for_spec(
    args : Array(String),
    cli : CLI = CLI.new,
  ) : ParsedInvocation
    parse_invocation(args, cli)
  end

  def self.validate_command_arguments_for_spec(
    valid_command : CLI::Command?,
    command_args : Array(String),
  ) : Nil
    validate_command_arguments(valid_command, command_args)
  end
end

private def parsed_invocation(args : Array(String)) : Tuple(Procodile::ParsedInvocation, Procodile::CLI)
  cli = Procodile::CLI.new
  {Procodile.parse_invocation_for_spec(args, cli), cli}
end

private def run_procodile_help(*args : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  executable = File.expand_path("../../bin/procodile", __DIR__)
  status = Process.run(executable, args.to_a, output: output, error: error)

  status.success?.should be_true
  error.to_s + output.to_s
end

describe Procodile do
  it "defaults to help when no command is given" do
    invocation, cli = parsed_invocation([] of String)

    invocation.command.should be_nil
    invocation.valid_command.should be_nil
    invocation.options.should eq({} of Symbol => String)
    invocation.command_args.should eq([] of String)
    cli.options.command_args.should be_nil
  end

  it "recognizes the help command without requiring an app" do
    invocation, _cli = parsed_invocation(["help"])

    invocation.command.should eq("help")
    invocation.valid_command.not_nil!.name.should eq("help")
    invocation.command_args.should eq([] of String)
  end

  it "parses global options before a subcommand" do
    invocation, cli = parsed_invocation(["-r", "/app", "--procfile", "PFile", "start", "-d"])

    invocation.command.should eq("start")
    invocation.valid_command.not_nil!.name.should eq("start")
    invocation.options.should eq({:root => "/app", :procfile => "PFile"})
    invocation.command_args.should eq([] of String)

    cli.options.foreground?.should be_true
    cli.options.proxy?.should be_true
    cli.options.stop_when_none?.should be_true
    cli.options.respawn?.should be_false
  end

  it "parses global options after a subcommand" do
    invocation, cli = parsed_invocation(["start", "-r", "app/app1", "--procfile", "config/PFile", "-d"])

    invocation.command.should eq("start")
    invocation.valid_command.not_nil!.name.should eq("start")
    invocation.options.should eq({:root => "app/app1", :procfile => "config/PFile"})
    invocation.command_args.should eq([] of String)

    cli.options.foreground?.should be_true
    cli.options.proxy?.should be_true
    cli.options.stop_when_none?.should be_true
    cli.options.respawn?.should be_false
  end

  it "preserves trailing command arguments for run" do
    invocation, _cli = parsed_invocation(["run", "bundle", "exec", "rake", "db:migrate"])

    invocation.command.should eq("run")
    invocation.valid_command.not_nil!.name.should eq("run")
    invocation.command_args.should eq(["bundle", "exec", "rake", "db:migrate"])
  end

  it "preserves trailing command arguments for exec" do
    invocation, _cli = parsed_invocation(["exec", "env"])

    invocation.command.should eq("exec")
    invocation.valid_command.not_nil!.name.should eq("exec")
    invocation.command_args.should eq(["env"])
  end

  it "keeps explicit process targets as command options and not command args" do
    invocation, cli = parsed_invocation(["restart", "-p", "app1,app2", "-t", "release-1"])

    invocation.command.should eq("restart")
    invocation.valid_command.not_nil!.name.should eq("restart")
    invocation.command_args.should eq([] of String)
    cli.options.processes.should eq("app1,app2")
    cli.options.tag.should eq("release-1")
  end

  it "captures positional args for start so validation can reject them" do
    invocation, _cli = parsed_invocation(["start", "worker.1"])

    invocation.command.should eq("start")
    invocation.command_args.should eq(["worker.1"])

    expect_raises(Procodile::Error, /Use `-p\/--processes`/) do
      Procodile.validate_command_arguments_for_spec(
        invocation.valid_command,
        invocation.command_args
      )
    end
  end

  it "treats unknown commands as plain command names without a valid command" do
    invocation, _cli = parsed_invocation(["not-a-command"])

    invocation.command.should eq("not-a-command")
    invocation.valid_command.should be_nil
    invocation.command_args.should eq([] of String)
  end

  it "prints start help with global and subcommand option sections" do
    output = run_procodile_help("start", "-h")

    output.should contain("Usage: procodile start [options]")
    output.should contain("Global options (can be used before or after the subcommand):")
    output.should contain("Subcommand options:")
    output.should contain("--stop-when-none")
  end

  it "prints status help with global and subcommand option sections" do
    output = run_procodile_help("status", "-h")

    output.should contain("Usage: procodile status [options]")
    output.should contain("Global options (can be used before or after the subcommand):")
    output.should contain("Subcommand options:")
    output.should contain("--json-pretty")
  end
end
