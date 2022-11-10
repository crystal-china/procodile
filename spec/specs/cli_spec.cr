require "../spec_helper"
require "../../src/procodile/cli"

describe Procodile::CLI do
  context "an application with a Procfile" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "full"))
    cli = Procodile::CLI.new
    cli.config = config

    it "should run help command" do
      command = cli.class.commands["help"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "help"
      command.description.should eq "Shows this help output"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      command.callable.call
    end

    it "should run kill command" do
      command = cli.class.commands["kill"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "kill"
      command.description.should eq "Forcefully kill all known processes"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      command.callable.call
    end

    it "should run start command" do
      command = cli.class.commands["start"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "start"
      command.description.should eq "Starts processes and/or the supervisor"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run stop command" do
      command = cli.class.commands["stop"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "stop"
      command.description.should eq "Stops processes and/or the supervisor"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run status command" do
      command = cli.class.commands["status"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "status"
      command.description.should eq "Show the current status of processes"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run exec command" do
      command = cli.class.commands["exec"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "exec"
      command.description.should eq "Execute a command within the environment"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run reload command" do
      command = cli.class.commands["reload"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "reload"
      command.description.should eq "Reload Procodile configuration"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run check_concurrency command" do
      command = cli.class.commands["check_concurrency"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "check_concurrency"
      command.description.should eq "Check process concurrency"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run log command" do
      command = cli.class.commands["log"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "log"
      command.description.should eq "Open/stream a Procodile log file"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end

    it "should run restart command" do
      command = cli.class.commands["restart"]
      command.should be_a Procodile::CliCommand
      command.name.should eq "restart"
      command.description.should eq "Restart processes"
      command.options.should be_a Proc(OptionParser, Procodile::CLI, Nil)
      command.callable.should be_a Proc(Nil)
      # command.callable.call
    end
  end
end
