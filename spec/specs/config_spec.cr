require "../spec_helper"
require "../../src/procodile/config"

describe Procodile::Config do
  context "an application with a Procfile" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "basic"))

    it "should have a default procfile path and options_path" do
      config.procfile_path.should eq File.join(APPS_ROOT, "basic", "Procfile")
      config.options_path.should eq File.join(APPS_ROOT, "basic", "Procfile.options")
      config.local_options_path.should eq File.join(APPS_ROOT, "basic", "Procfile.local")
    end

    it "should not have any options" do
      config.options.should be_a Procodile::Config::Option
      config.options.should eq Procodile::Config::Option.new
    end

    it "should not have any local options" do
      config.local_options.should be_a Procodile::Config::Option
      config.local_options.should eq Procodile::Config::Option.new
    end

    it "should have a determined pid root and socket path" do
      config.pid_root.should eq File.join(APPS_ROOT, "basic", "pids")
      config.sock_path.should eq File.join(APPS_ROOT, "basic", "pids", "procodile.sock")
    end

    it "should have a supervisor pid path" do
      config.supervisor_pid_path.should eq File.join(APPS_ROOT, "basic", "pids", "procodile.pid")
    end

    it "should have a determined log file" do
      config.log_path.should eq File.join(APPS_ROOT, "basic", "procodile.log")
    end

    it "should not have a log root" do
      config.log_root.should be_nil
    end

    context "the process list" do
      process_list = config.processes

      it "should be a hash" do
        process_list.should be_a Hash(String, Procodile::Process)
      end

      context "a created process" do
        process = config.processes["web"]

        it "should be a process object" do
          process.should be_a Procodile::Process
        end

        it "should have a suitable command" do
          process.command.should eq "ruby process.rb web"
        end

        it "should have a log color" do
          process.log_color.should eq 35
        end
      end
    end
  end

  context "an application without a Procfile" do
    it "should raise an error" do
      expect_raises(Procodile::Error, /Procfile not found at/) do
        Procodile::Config.new(File.join(APPS_ROOT, "empty"))
      end
    end
  end

  context "an application with options" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "full"))

    # it "should have options", focus: true do
    #   # config.options.size.should_not eq 0
    # end

    it "should return the app name" do
      config.app_name.should eq "specapp"
    end

    it "should return a custom pid root" do
      config.pid_root.should eq File.join(APPS_ROOT, "full", "tmp/pids")
    end

    it "should have the socket in the custom pid root" do
      config.sock_path.should eq File.join(APPS_ROOT, "full", "tmp/pids/procodile.sock")
    end

    it "should have the supervisor pid in the custom pid root" do
      config.supervisor_pid_path.should eq File.join(APPS_ROOT, "full", "tmp/pids/procodile.pid")
    end

    it "should have environment variables" do
      config.environment_variables.should be_a Hash(String, String)
      config.environment_variables["FRUIT"].should eq "apple"
    end

    it "should stringify values on environment variables" do
      config.environment_variables["PORT"].should eq "3000"
    end

    it "should flatten environment variables that have environment variants" do
      config.environment_variables["VEGETABLE"].should eq "potato"
    end

    it "should a custom log path" do
      config.log_path.should eq File.join(APPS_ROOT, "full", "log/procodile.log")
    end

    it "should return a console command" do
      config.console_command.should eq "irb -Ilib"
    end

    it "should return an exec prefix" do
      config.exec_prefix.should eq "bundle exec"
    end

    it "should be able to return options for a process" do
      config.options_for_process("proc1").should be_a Procodile::Process::Option
      config.options_for_process("proc1").quantity.should eq 2
      config.options_for_process("proc1").restart_mode.should eq Signal::USR2
      config.options_for_process("proc2").should be_a Procodile::Process::Option
      config.options_for_process("proc2").should eq Procodile::Process::Option.new
    end
  end

  context "reloading configuration" do
    saved_procfile_content = "proc1: ruby process.rb
proc2: ruby process.rb
proc3: ruby process.rb
proc4: ruby process.rb
"

    saved_options_content = "app_name: specapp
pid_root: tmp/pids
log_path: log/procodile.log
console_command: irb -Ilib
exec_prefix: bundle exec
env:
  RAILS_ENV: production
  FRUIT: apple
  VEGETABLE: potato
  PORT: 3000
processes:
  proc1:
    quantity: 2
    restart_mode: USR2
    term_signal: TERM
    allocate_port_from: 3005
    proxy_address: 127.0.0.1
    proxy_port: 2018
    network_protocol: tcp
"

    it "should add missing processes" do
      config = Procodile::Config.new(File.join(APPS_ROOT, "full"))

      config.process_list.size.should eq 4

      new_procfile_hash = Hash(String, String).from_yaml(saved_procfile_content)
      new_procfile_hash["proc5"] = "ruby process.rb"
      File.write(config.procfile_path, new_procfile_hash.to_yaml)

      config.reload

      config.process_list.size.should eq 5
      config.process_list["proc5"].should eq "ruby process.rb"

      File.write(config.procfile_path, saved_procfile_content)
    end

    it "should remove removed processes" do
      config = Procodile::Config.new(File.join(APPS_ROOT, "full"))

      config.process_list.size.should eq 4

      new_procfile_hash = Hash(String, String).from_yaml(saved_procfile_content)
      new_procfile_hash.delete("proc4")
      File.write(config.procfile_path, new_procfile_hash.to_yaml)

      config.reload

      config.process_list.size.should eq 3
      config.process_list["proc4"]?.should be_nil

      File.write(config.procfile_path, saved_procfile_content)
    end

    it "should update existing processes" do
      config = Procodile::Config.new(File.join(APPS_ROOT, "full"))

      config.process_list["proc4"].should eq "ruby process.rb"

      new_procfile_hash = Hash(String, String).from_yaml(saved_procfile_content)
      new_procfile_hash["proc4"] = "ruby process2.rb"
      File.write(config.procfile_path, new_procfile_hash.to_yaml)

      config.reload

      config.process_list["proc4"].should eq "ruby process2.rb"

      File.write(config.procfile_path, saved_procfile_content)
    end

    it "should update processes when options change" do
      config = Procodile::Config.new(File.join(APPS_ROOT, "full"))

      config.options_for_process("proc1").restart_mode.should eq Signal::USR2

      File.write(config.options_path, saved_options_content.sub("term-start", "usr2"))

      config.reload

      config.options_for_process("proc1").restart_mode.should eq Signal::USR2

      File.write(config.options_path, saved_options_content)
    end
  end
end
