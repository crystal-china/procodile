require "../spec_helper"

private def build_control_session_app(procfile : String)
  app_root = File.join("/tmp", "procodile-control-session-#{Random.rand(1_000_000)}")
  FileUtils.mkdir_p(File.join(app_root, "pids"))
  File.write(File.join(app_root, "Procfile"), procfile)

  config = Procodile::Config.new(root: app_root)
  supervisor = Procodile::Supervisor.new(config)
  client = UNIXSocket.pair[0]
  session = Procodile::ControlSession.new(supervisor, client)

  {app_root, supervisor, client, session}
end

private def cleanup_control_session_app(
  app_root : String,
  supervisor : Procodile::Supervisor,
  client : UNIXSocket,
)
  supervisor.processes.each_value do |instances|
    instances.each(&.stop)
  end

  wait_until(5.seconds, 50.milliseconds) do
    supervisor.processes.values.flatten.none?(&.running?)
  end

  client.close rescue nil
  FileUtils.rm_rf(app_root)
end

describe Procodile::ControlSession do
  it "dispatches status through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 1\n")

    begin
      response = session.receive_data(%(status {}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = Procodile::ControlClient::ReplyOfStatusCommand.from_json(reply)
      parsed.root.should eq(app_root)
      parsed.processes.map(&.name).should contain("app1")
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "dispatches reload_config through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 1\n")

    begin
      response = session.receive_data(%(reload_config {}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = NamedTuple(ok: Bool).from_json(reply)
      parsed[:ok].should be_true
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "dispatches start_processes through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 60\n")

    begin
      response = session.receive_data(%(start_processes {}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = Array(Procodile::Instance::Config).from_json(reply)
      parsed.size.should eq(1)
      parsed.first.description.should eq("app1.1")

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app1" && instance.running? }
      end.should be_true
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "dispatches stop through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 60\n")

    begin
      supervisor.start_processes(nil)

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app1" && instance.running? }
      end.should be_true

      response = session.receive_data(%(stop {"process_names":["app1"]}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = Array(Procodile::Instance::Config).from_json(reply)
      parsed.size.should eq(1)
      parsed.first.description.should eq("app1.1")
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "dispatches restart through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 60\n")

    begin
      supervisor.start_processes(nil)

      wait_until(2.seconds, 50.milliseconds) do
        supervisor.processes.values.flatten.any? { |instance| instance.process.name == "app1" && instance.running? }
      end.should be_true

      response = session.receive_data(%(restart {"process_names":["app1"]}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = Array(Tuple(Procodile::Instance::Config?, Procodile::Instance::Config?)).from_json(reply)
      parsed.size.should eq(1)
      parsed.first[0].should_not be_nil
      parsed.first[1].should_not be_nil
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "dispatches check_concurrency through receive_data" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 60\n")

    begin
      response = session.receive_data(%(check_concurrency {"reload":false}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = NamedTuple(
        started: Array(Procodile::Instance::Config),
        stopped: Array(Procodile::Instance::Config)).from_json(reply)
      parsed[:started].size.should eq(1)
      parsed[:started].first.description.should eq("app1.1")
      parsed[:stopped].should be_empty
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end

  it "returns 404 for an unknown command" do
    app_root, supervisor, client, session = build_control_session_app("app1: sleep 1\n")

    begin
      session.receive_data(%(not-a-command {})).should eq("404 Invalid command")
    ensure
      cleanup_control_session_app(app_root, supervisor, client)
    end
  end
end
