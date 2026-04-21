require "../spec_helper"

private def run_procodile_command(app_root : String, *args : String) : {::Process::Status, String}
  binary = procodile_test_binary
  output = IO::Memory.new
  status = ::Process.run(
    binary,
    ["-r", app_root] + args.to_a,
    output: output,
    error: output
  )

  {status, output.to_s}
end

private def procodile_test_binary : String
  binary = "/tmp/procodile-env-spec-bin"

  status = ::Process.run(
    "crystal",
    ["build", "src/procodile.cr", "-o", binary],
    output: Process::Redirect::Close,
    error: Process::Redirect::Inherit,
    env: {"CRYSTAL_CACHE_DIR" => "/tmp/crystal-cache"}
  )
  raise "failed to build procodile test binary" unless status.success?

  binary
end

private def wait_for_control_socket(sock_path : String, timeout : Time::Span = 5.seconds) : Bool
  wait_until(timeout, 50.milliseconds) do
    begin
      UNIXSocket.new(sock_path).close
      true
    rescue Socket::Error | File::Error
      false
    end
  end
end

describe "env file support" do
  it "overrides global env and is overridden by process-specific env" do
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
      env_output.should contain("VEGETABLE=carrot")
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

  it "creates a runtime issue when the env file is missing during process start" do
    app_root = File.join("/tmp", "procodile-missing-env-file-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 2
SH
    )
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(File.join(app_root, "Procfile"), "app1: bash ok.sh\n")

    config = Procodile::Config.new(root: app_root)
    run_options = Procodile::Supervisor::RunOptions.new(
      env_file: ".missing.env",
      foreground: false
    )
    supervisor = Procodile::Supervisor.new(config, run_options)

    begin
      supervisor.start_processes(nil).should be_empty

      issue = supervisor.runtime_issues_for_spec.find(&.type.process_failed_permanently?)
      issue.should_not be_nil
      issue = issue.not_nil!
      issue.process_name.should eq("app1")
      issue.message.should contain("Process 'app1' failed to start")
      issue.message.should contain(".missing.env")
      issue.message.should contain("could not be found")
      supervisor.processes.values.flatten.should be_empty
    ensure
      FileUtils.rm_rf(app_root)
    end
  end

  it "prints runtime issues after start when the requested env file does not exist" do
    app_root = File.join("/tmp", "procodile-cli-env-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))
    File.write(File.join(app_root, "Procfile"), "app1: /bin/sleep 2\n")

    begin
      status, output = run_procodile_command(app_root, "start", "--env-file", ".env")

      status.success?.should be_true
      output.should contain("Started Procodile supervisor with PID")
      output.should contain("Active issues:")
      output.should contain("Process 'app1' failed to start: The file #{File.join(app_root, ".env")} could not be found.")
      File.exists?(File.join(app_root, "pids", "procodile.pid")).should be_true
    ensure
      run_procodile_command(app_root, "kill")
      FileUtils.rm_rf(app_root)
    end
  end

  it "prints runtime issues after restart when the env file is removed" do
    app_root = File.join("/tmp", "procodile-restart-env-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "sleep.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 30
SH
    )
    File.chmod(File.join(app_root, "sleep.sh"), 0o755)
    File.write(File.join(app_root, "Procfile"), "app1: bash sleep.sh\n")
    File.write(File.join(app_root, ".env"), "FOO=bar\n")

    output = IO::Memory.new
    process = nil.as(::Process?)

    begin
      config = Procodile::Config.new(root: app_root)
      process = ::Process.new(
        procodile_test_binary,
        ["-r", app_root, "start", "-f", "--env-file", ".env"],
        output: output,
        error: output
      )

      wait_for_control_socket(config.sock_path).should be_true

      FileUtils.rm_rf(File.join(app_root, ".env"))

      restart_status, restart_output = run_procodile_command(app_root, "restart")
      restart_status.success?.should be_true
      restart_output.should contain("Active issues:")
      restart_output.should contain("Process 'app1' failed to start: The file #{File.join(app_root, ".env")} could not be found.")
    ensure
      process.try &.terminate
      process.try &.wait
      FileUtils.rm_rf(app_root)
    end
  end
end
