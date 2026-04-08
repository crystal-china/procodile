require "../spec_helper"

private def wait_for_control_socket(sock_path : String) : Bool
  wait_until(5.seconds, 50.milliseconds) do
    begin
      UNIXSocket.new(sock_path).close
      true
    rescue Socket::Error | File::Error
      false
    end
  end
end

private def run_cli_command(app_root : String, *args : String) : {::Process::Status, String}
  output = IO::Memory.new
  status = ::Process.run(
    "crystal",
    ["run", "src/procodile.cr", "--", "-r", app_root] + args.to_a,
    output: output,
    error: output,
    env: {"CRYSTAL_CACHE_DIR" => "/tmp/crystal-cache"}
  )

  {status, output.to_s}
end

describe "runtime issues" do
  it "prints invalid schedule issues after CLI commands and clears them after reload with a valid schedule" do
    app_root = File.join("/tmp", "procodile-invalid-schedule-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts "tick"
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__*/2 * * * **": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any?(&.type.invalid_schedule?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should contain("Active issues:")
      output.should contain("Scheduled process 'job' has invalid cron schedule '*/2 * * * **'")

      File.write(
        File.join(app_root, "Procfile"),
        %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
      )

      supervisor.reload_config

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none?(&.type.invalid_schedule?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should_not contain("Active issues:")
      output.should_not contain("invalid cron schedule")
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config
      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "reports permanent process failures and clears the issue after a successful restart" do
    app_root = File.join("/tmp", "procodile-process-failure-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "fail.sh"),
      <<-'SH'
#!/usr/bin/env bash
exit 1
SH
    )
    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 2
SH
    )
    File.chmod(File.join(app_root, "fail.sh"), 0o755)
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(File.join(app_root, "Procfile"), "app1: bash fail.sh\n")
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-'YAML'
processes:
  app1:
    max_respawns: 0
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["app1"]
    instance = process.create_instance(supervisor)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      instance.start

      wait_until(5.seconds, 50.milliseconds) { !instance.running? }.should be_true
      instance.check

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any?(&.type.process_failed_permanently?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should contain("Active issues:")
      output.should contain("Process 'app1' failed repeatedly and will not be respawned automatically")

      File.write(File.join(app_root, "Procfile"), "app1: bash ok.sh\n")
      supervisor.restart(Procodile::Supervisor::Options.new(processes: ["app1"]))

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none?(&.type.process_failed_permanently?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should_not contain("Active issues:")
      output.should_not contain("failed repeatedly")
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "reports process start failures, keeps the supervisor alive, and clears the issue after restart" do
    app_root = File.join("/tmp", "procodile-process-start-failure-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 2
SH
    )
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(
      File.join(app_root, "Procfile"),
      <<-'PROCFILE'
app1: /definitely/not/exist/foo1.sh
app2: bash ok.sh
PROCFILE
    )
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-'YAML'
processes:
  app1:
    max_respawns: 0
  app2:
    max_respawns: 0
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      started = supervisor.start_processes(nil)
      started.map(&.process.name).should eq(["app2"])

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any?(&.type.process_failed_permanently?)
      end.should be_true

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app2" && instance.running? }
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should contain("Active issues:")
      output.should contain("Process 'app1' failed to start:")
      output.should contain("/definitely/not/exist/foo1.sh")

      File.write(
        File.join(app_root, "Procfile"),
        <<-'PROCFILE'
app1: bash ok.sh
app2: bash ok.sh
PROCFILE
      )

      restart_status, restart_output = run_cli_command(app_root, "restart", "-p", "app1")
      restart_status.success?.should be_true
      restart_output.should contain("Started")
      restart_output.should_not contain("Active issues:")

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none?(&.type.process_failed_permanently?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should_not contain("Active issues:")
      output.should_not contain("Failed to start.")
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "stops a removed running process without disconnecting the control server" do
    app_root = File.join("/tmp", "procodile-stop-removed-process-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 10
SH
    )
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(File.join(app_root, "Procfile"), "app1: bash ok.sh\n")
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-'YAML'
processes:
  app1:
    max_respawns: 0
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).map(&.process.name).should eq(["app1"])

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app1" && instance.running? }
      end.should be_true

      File.write(File.join(app_root, "Procfile"), "app2: bash ok.sh\n")
      File.write(
        File.join(app_root, "Procfile.options"),
        <<-'YAML'
processes:
  app2:
    max_respawns: 0
YAML
      )
      supervisor.reload_config

      stop_status, stop_output = run_cli_command(app_root, "stop", "-p", "app1")
      stop_status.success?.should be_true
      stop_output.should contain("Stopped")
      stop_output.should contain("app1.")
      stop_output.should_not contain("Control server disconnected")

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none? { |instance| instance.process.name == "app1" && instance.running? }
      end.should be_true
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "clears scheduled run failed issues after stopping a scheduled process" do
    app_root = File.join("/tmp", "procodile-stop-scheduled-issue-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "fail.sh"),
      <<-'SH'
#!/usr/bin/env bash
exit 1
SH
    )
    File.chmod(File.join(app_root, "fail.sh"), 0o755)

    File.write(File.join(app_root, "Procfile"), "app1: bash fail.sh\n")
    File.write(
      File.join(app_root, "Procfile.local"),
      <<-'YAML'
processes:
  app1:
    at: "*/1 * * * * *"
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any?(&.type.scheduled_run_failed?)
      end.should be_true

      stop_status, stop_output = run_cli_command(app_root, "stop", "-p", "app1")
      stop_status.success?.should be_true
      stop_output.should contain("Future scheduling was disabled for app1.")
      stop_output.should_not contain("Active issues:")

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none?(&.type.scheduled_run_failed?)
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should_not contain("Scheduled process 'app1' failed with exit status")
      output.should_not contain("Active issues:")
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "clears runtime issues after a removed process is stopped and fully removed" do
    app_root = File.join("/tmp", "procodile-clear-removed-issues-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "fail.sh"),
      <<-'SH'
#!/usr/bin/env bash
exit 1
SH
    )
    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
sleep 10
SH
    )
    File.chmod(File.join(app_root, "fail.sh"), 0o755)
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(
      File.join(app_root, "Procfile"),
      <<-'PROCFILE'
app1: bash fail.sh
app2: bash ok.sh
PROCFILE
    )
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-'YAML'
processes:
  app1:
    max_respawns: 0
  app2:
    max_respawns: 0
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      spawn do
        supervisor.start(->(s : Procodile::Supervisor) { s.start_processes(nil) })
      end

      wait_for_control_socket(config.sock_path).should be_true

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any? { |issue| issue.type.process_failed_permanently? && issue.process_name == "app1" }
      end.should be_true

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app2" && instance.running? }
      end.should be_true

      File.write(File.join(app_root, "Procfile"), "app2: bash ok.sh\n")
      File.write(
        File.join(app_root, "Procfile.options"),
        <<-'YAML'
processes:
  app2:
    max_respawns: 0
YAML
      )
      supervisor.reload_config

      stop_status, stop_output = run_cli_command(app_root, "stop", "-p", "app1")
      stop_status.success?.should be_true
      stop_output.should contain("Stopped")
      stop_output.should contain("app1.")

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none? { |issue| issue.process_name == "app1" }
      end.should be_true

      status, output = run_cli_command(app_root, "status")
      status.success?.should be_true
      output.should_not contain("Process 'app1' failed")
      output.should_not contain("Active issues:")
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "restores a scheduled process with restart after fixing an invalid schedule" do
    app_root = File.join("/tmp", "procodile-invalid-schedule-restart-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts "tick"
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__*/2 * * * **": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.any?(&.type.invalid_schedule?)
      end.should be_true

      File.write(
        File.join(app_root, "Procfile"),
        %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
      )

      restart_status, restart_output = run_cli_command(app_root, "restart", "-p", "job")
      restart_status.success?.should be_true
      restart_output.should contain("Reloaded schedule for job.")

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.runtime_issues.none?(&.type.invalid_schedule?)
      end.should be_true

      output_file = File.join(app_root, "schedule.out")
      wait_until(5.seconds, 100.milliseconds) do
        File.exists?(output_file) && !File.read(output_file).empty?
      end.should be_true
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config
      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "skips removed running processes during full restart" do
    app_root = File.join("/tmp", "procodile-restart-skips-removed-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "ok.sh"),
      <<-'SH'
#!/usr/bin/env bash
echo $$ >> app.log
sleep 10
SH
    )
    File.chmod(File.join(app_root, "ok.sh"), 0o755)

    File.write(
      File.join(app_root, "Procfile"),
      <<-'PROCFILE'
app1: bash ok.sh
app2: bash ok.sh
PROCFILE
    )
    File.write(
      File.join(app_root, "Procfile.options"),
      <<-'YAML'
processes:
  app1:
    max_respawns: 0
  app2:
    max_respawns: 0
YAML
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).map(&.process.name).sort!.should eq(["app1", "app2"])

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.count(&.running?) == 2
      end.should be_true

      removed_instance = supervisor.processes.values.flatten.find { |instance| instance.process.name == "app1" && instance.running? }.not_nil!
      removed_description = removed_instance.description

      File.write(File.join(app_root, "Procfile"), "app2: bash ok.sh\n")
      File.write(
        File.join(app_root, "Procfile.options"),
        <<-'YAML'
processes:
  app2:
    max_respawns: 0
YAML
      )
      supervisor.reload_config

      restart_status, restart_output = run_cli_command(app_root, "restart")
      restart_status.success?.should be_true
      restart_output.should contain("Skipped #{removed_description}, it is still running but has been removed from the Procfile")

      still_running = supervisor.processes.values.flatten.find { |instance| instance.description == removed_description }
      still_running.should_not be_nil
      still_running.not_nil!.running?.should be_true
    ensure
      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end
end
