require "../spec_helper"
require "../../src/procodile/config"
require "../../src/procodile/process"
require "../../src/procodile/supervisor"

describe Procodile::Process do
  config = Procodile::Config.new(root: File.join(APPS_ROOT, "full"))
  process = Procodile::Process.new(config, "proc1", "ruby process.rb", config.options_for_process("proc1"))

  it "should return correct attributes" do
    process.quantity.should be_a Int32
    process.quantity.should eq 2

    process.max_respawns.should be_a Int32
    process.max_respawns.should eq 5

    process.respawn_window.should be_a Int32
    process.respawn_window.should eq 3600

    process.log_path.should be_a String
    process.log_path.should end_with "apps/full/proc1.log"

    process.term_signal.should be_a Signal
    process.term_signal.should eq Signal::TERM

    process.restart_mode.should be_a Signal
    process.restart_mode.should eq Signal::USR2

    process.allocate_port_from.should be_a Int32
    process.allocate_port_from.should eq 3005

    process.proxy?.should be_a Bool
    process.proxy?.should be_true

    process.proxy_port.should be_a Int32
    process.proxy_port.should eq 2018

    process.proxy_address.should be_a String
    process.proxy_address.should eq "127.0.0.1"

    process.network_protocol.should be_a String
    process.network_protocol.should eq "tcp"
  end

  # it "should create a new instance" do
  #   supervisor = Procodile::Supervisor.new(config)
  #   process.create_instance
  # end
end
