require "../spec_helper"

describe "env file support" do
  it "overrides global env but not process-specific env" do
    app_root = File.join("/tmp", "procodile-env-file-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "dump_env.rb"),
      <<-'RUBY'
File.write(
  "env.out",
  [
    "FRUIT=#{ENV["FRUIT"]}",
    "VEGETABLE=#{ENV["VEGETABLE"]}",
    "ANIMAL=#{ENV["ANIMAL"]}",
    "PROC_NAME=#{ENV["PROC_NAME"]}",
    "APP_ROOT=#{ENV["APP_ROOT"]}",
    "PORT=#{ENV["PORT"]}",
  ].join("\n")
)
trap("TERM") { exit }
sleep
RUBY
    )

    File.write(File.join(app_root, "Procfile"), "app1: ruby dump_env.rb\n")
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-YAML
env:
  FRUIT: apple
  VEGETABLE: potato
processes:
  app1:
    allocate_port_from: 3005
    env:
      VEGETABLE: carrot
YAML
    )
    File.write(
      File.join(app_root, ".env"),
      <<-ENV
FRUIT=orange
VEGETABLE=onion
ANIMAL=cat
PROC_NAME=wrong
APP_ROOT=/tmp/wrong
PORT=9999
ENV
    )

    config = Procodile::Config.new(root: app_root)
    run_options = Procodile::Supervisor::RunOptions.new(
      env_file: ".env",
      foreground: false
    )
    supervisor = Procodile::Supervisor.new(config, run_options)
    instance = supervisor.start_processes(nil).first
    output_file = File.join(app_root, "env.out")

    begin
      wait_until(5.seconds, 100.milliseconds) { File.exists?(output_file) }.should be_true

      env_output = File.read(output_file)
      env_output.should contain("FRUIT=orange")
      env_output.should contain("VEGETABLE=onion")
      env_output.should contain("ANIMAL=cat")
      env_output.should contain("PROC_NAME=app1.1")
      env_output.should contain("APP_ROOT=#{app_root}")
      env_output.should contain("PORT=#{instance.port}")
    ensure
      instance.stop
      wait_until(5.seconds) { !instance.running? }
      instance.on_stop
      FileUtils.rm_rf(app_root)
    end
  end
end
