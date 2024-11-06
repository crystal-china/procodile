require "../spec_helper"
require "../../src/procodile/procfile_option"

describe Procodile::ProcfileOption do
  it "should allow root and procfile to be provided" do
    procfile_option_file = File.join(APPS_ROOT, "full", "Procfile.options")
    procfile_option = Procodile::ProcfileOption.from_yaml(File.read(procfile_option_file))
    procfile_option.app_name.should eq "specapp"
    procfile_option.pid_root.should eq "tmp/pids"
    procfile_option.log_path.should eq "log/procodile.log"
    procfile_option.exec_prefix.should eq "bundle exec"
    procfile_option.env.should eq({"RAILS_ENV" => "production", "FRUIT" => "apple", "VEGETABLE" => "potato", "PORT" => "3000"})

    procfile_option.processes.should be_a Hash(String, Procodile::Process::Option)

    process_option = Procodile::Process::Option.new
    process_option.quantity = 2
    process_option.restart_mode = Signal::USR2
    process_option.term_signal = Signal::TERM
    process_option.allocate_port_from = 3005
    process_option.proxy_address = "127.0.0.1"
    process_option.proxy_port = 2018
    process_option.network_protocol = "tcp"

    procfile_option.processes.should eq({"proc1" => process_option})
  end
end
