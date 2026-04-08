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

private def run_status_command(app_root : String) : String
  output = IO::Memory.new
  status = ::Process.run(
    "crystal",
    ["run", "src/procodile.cr", "--", "-r", app_root, "status"],
    output: output,
    error: output,
    env: {"CRYSTAL_CACHE_DIR" => "/tmp/crystal-cache"}
  )

  status.success?.should be_true
  output.to_s
end

describe "scheduled processes" do
  it "runs on schedule, records last run details, and skips overlap" do
    app_root = File.join("/tmp", "procodile-scheduled-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts "start"
end

sleep 1.5

File.open("schedule.out", "a") do |file|
  file.puts "finish"
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      supervisor.start_processes(nil).should be_empty

      output_file = File.join(app_root, "schedule.out")

      wait_until(8.seconds, 100.milliseconds) do
        !process.last_finished_at.nil? &&
          process.last_exit_status == 0 &&
          !process.last_run_duration.nil?
      end.should be_true

      wait_until(8.seconds, 100.milliseconds) do
        File.exists?(output_file) && File.read_lines(output_file).size >= 4
      end.should be_true

      process.last_started_at.should_not be_nil
      process.last_finished_at.should_not be_nil
      process.last_exit_status.should eq(0)
      process.last_run_duration.should_not be_nil
      process.last_run_duration.not_nil!.should be >= 1.4

      lines = File.read_lines(output_file)
      lines.each_slice(2) do |slice|
        next unless slice.size == 2

        slice[0].should eq("start")
        slice[1].should eq("finish")
      end
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config

      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 100.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(app_root)
    end
  end

  it "prints scheduled processes without daemon-only status fields" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-status-#{Random.rand(1_000_000)}")
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
      %Q("job__AT__*/5 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      File.write(config.supervisor_pid_path, ::Process.pid.to_s)
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      output = run_status_command(app_root)

      output.should contain("|| job")
      output.should contain("Schedule            */5 * * * * *")
      output.should contain("No scheduled runs in progress.")
      output.should_not contain("Quantity            ")
      output.should_not contain("Respawning          ")
      output.should_not contain("Restart mode        ")
      output.should_not contain("Address/Port        ")
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config
      FileUtils.rm_rf(config.supervisor_pid_path)
      FileUtils.rm_rf(app_root)
    end
  end

  it "stops future runs through the control socket and start_processes reenables schedule without running immediately" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-stop-#{Random.rand(1_000_000)}")
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
      %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      output_file = File.join(app_root, "schedule.out")

      wait_until(8.seconds, 100.milliseconds) do
        File.exists?(output_file) && File.read_lines(output_file).size >= 1
      end.should be_true

      wait_until(5.seconds, 100.milliseconds) do
        !process.last_finished_at.nil?
      end.should be_true

      first_lines = File.read_lines(output_file)
      first_lines.size.should be >= 1

      Procodile::ControlClient.run(config.sock_path, "stop", processes: ["job"])

      sleep 2.2.seconds

      File.read_lines(output_file).size.should eq(first_lines.size)

      process.last_started_at.should_not be_nil
      process.last_finished_at.should_not be_nil

      before_restart_started_at = process.last_started_at

      supervisor.start_processes(["job"]).should be_empty

      process.last_started_at.should eq(before_restart_started_at)

      sleep 0.3.seconds

      File.read_lines(output_file).size.should eq(first_lines.size)

      wait_until(5.seconds, 100.milliseconds) do
        File.read_lines(output_file).size > first_lines.size
      end.should be_true
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config

      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 100.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(app_root)
    end
  end

  it "does not execute immediately when restarted through the control socket" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-restart-#{Random.rand(1_000_000)}")
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
      %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      Procodile::ControlServer.start(supervisor)
      wait_for_control_socket(config.sock_path).should be_true

      supervisor.start_processes(nil).should be_empty

      output_file = File.join(app_root, "schedule.out")
      wait_until(8.seconds, 100.milliseconds) do
        File.exists?(output_file) && File.read_lines(output_file).size >= 1
      end.should be_true

      first_run_count = File.read_lines(output_file).size

      Procodile::ControlClient.run(config.sock_path, "restart", processes: ["job"])

      sleep 0.3.seconds

      File.read_lines(output_file).size.should eq(first_run_count)

      wait_until(5.seconds, 100.milliseconds) do
        File.read_lines(output_file).size > first_run_count
      end.should be_true
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config
      FileUtils.rm_rf(app_root)
    end
  end

  it "uses the new schedule immediately after reload" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-reload-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))
    initial_second = (Time.local.second + 10) % 60

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts Time.local.to_unix_ms
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__#{initial_second} * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      supervisor.start_processes(nil).should be_empty

      sleep 1.2.seconds
      process.last_started_at.should be_nil

      File.write(
        File.join(app_root, "Procfile"),
        %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
      )

      reload_started_at = Time.local
      supervisor.reload_config

      wait_until(3.seconds, 100.milliseconds) do
        if started_at = process.last_started_at
          started_at >= reload_started_at
        else
          false
        end
      end.should be_true
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config
      FileUtils.rm_rf(app_root)
    end
  end

  it "reports repeated skipped runs and clears the issue after a successful run" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-skip-issue-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts "start"
end

sleep 3.5

File.open("schedule.out", "a") do |file|
  file.puts "finish"
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    process = config.processes["job"]

    begin
      supervisor.start_processes(nil).should be_empty

      wait_until(8.seconds, 100.milliseconds) do
        supervisor.runtime_issues.any?(&.type.scheduled_run_skipped_repeatedly?)
      end.should be_true

      File.write(
        File.join(app_root, "scheduled_task.rb"),
        <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts "fast"
end
RUBY
      )

      wait_until(8.seconds, 100.milliseconds) do
        process.last_finished_at != nil &&
          supervisor.runtime_issues.none?(&.type.scheduled_run_skipped_repeatedly?)
      end.should be_true
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config

      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 100.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(app_root)
    end
  end

  it "does not restart a running scheduled instance during full restart" do
    app_root = File.join(Dir.current, "spec/tmp/procodile-scheduled-full-restart-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    File.write(
      File.join(app_root, "scheduled_task.rb"),
      <<-'RUBY'
File.open("schedule.out", "a") do |file|
  file.puts Process.pid
end

sleep 3
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      %Q("job__AT__*/1 * * * * *": env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n)
    )

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)

    begin
      supervisor.start_processes(nil).should be_empty

      output_file = File.join(app_root, "schedule.out")
      wait_until(8.seconds, 100.milliseconds) do
        File.exists?(output_file) && File.read_lines(output_file).size >= 1 &&
          supervisor.processes.values.flatten.any? { |instance| instance.process.name == "job" && instance.running? }
      end.should be_true

      first_run_count = File.read_lines(output_file).size
      running_instance = supervisor.processes.values.flatten.find { |instance| instance.process.name == "job" && instance.running? }.not_nil!
      first_description = running_instance.description

      supervisor.restart

      sleep 0.5.seconds

      File.read_lines(output_file).size.should eq(first_run_count)
      current_running_instance = supervisor.processes.values.flatten.find { |instance| instance.process.name == "job" && instance.running? }.not_nil!
      current_running_instance.description.should eq(first_description)
    ensure
      File.write(File.join(app_root, "Procfile"), "noop: env -u RUBYOPT -u RUBYLIB ruby scheduled_task.rb\n")
      supervisor.reload_config

      supervisor.processes.each_value do |instances|
        instances.each(&.stop)
      end

      wait_until(5.seconds, 100.milliseconds) do
        supervisor.processes.values.flatten.none?(&.running?)
      end

      FileUtils.rm_rf(app_root)
    end
  end
end
