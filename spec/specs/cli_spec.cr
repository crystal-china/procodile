require "../spec_helper"
require "../../src/procodile/cli"

describe Procodile::CLI do
  context "an application with a Procfile" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "full"))
    cli = Procodile::CLI.new
    cli.config = config

    it "should run help command" do
      help_command = cli.class.commands["help"]
      help_command.should be_a Procodile::CliCommand
      help_command.name.should eq "help"
      help_command.description.should eq "Shows this help output"
      help_command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      help_command.callable.should be_a Proc(Nil)
      help_command.callable.call
    end

    it "should run kill command" do
      kill_command = cli.class.commands["kill"]
      kill_command.should be_a Procodile::CliCommand
      kill_command.name.should eq "kill"
      kill_command.description.should eq "Forcefully kill all known processes"
      kill_command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      kill_command.callable.should be_a Proc(Nil)
      kill_command.callable.call
    end

    it "should run start command" do
      start_command = cli.class.commands["start"]
      start_command.should be_a Procodile::CliCommand
      start_command.name.should eq "start"
      start_command.description.should eq "Starts processes and/or the supervisor"
      start_command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      start_command.callable.should be_a Proc(Nil)
      # start_command.callable.call
    end
  end
end
