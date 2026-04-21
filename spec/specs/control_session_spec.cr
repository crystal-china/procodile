require "../spec_helper"

describe Procodile::ControlSession do
  it "dispatches status through receive_data" do
    app_root = File.join("/tmp", "procodile-control-session-status-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))
    File.write(File.join(app_root, "Procfile"), "app1: sleep 1\n")

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    client = UNIXSocket.pair[0]
    session = Procodile::ControlSession.new(supervisor, client)

    begin
      response = session.receive_data(%(status {}))

      response.should start_with("200 ")
      reply = response.sub(/\A200\s+/, "")
      parsed = Procodile::ControlClient::ReplyOfStatusCommand.from_json(reply)
      parsed.root.should eq(app_root)
      parsed.processes.map(&.name).should contain("app1")
    ensure
      client.close rescue nil
      FileUtils.rm_rf(app_root)
    end
  end

  it "dispatches reload_config through receive_data" do
    app_root = File.join("/tmp", "procodile-control-session-reload-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))
    File.write(File.join(app_root, "Procfile"), "app1: sleep 1\n")

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    client = UNIXSocket.pair[0]
    session = Procodile::ControlSession.new(supervisor, client)

    begin
      response = session.receive_data(%(reload_config {}))

      response.should eq("200 []")
    ensure
      client.close rescue nil
      FileUtils.rm_rf(app_root)
    end
  end

  it "returns 404 for an unknown command" do
    app_root = File.join("/tmp", "procodile-control-session-invalid-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(File.join(app_root, "pids"))
    File.write(File.join(app_root, "Procfile"), "app1: sleep 1\n")

    config = Procodile::Config.new(root: app_root)
    supervisor = Procodile::Supervisor.new(config)
    client = UNIXSocket.pair[0]
    session = Procodile::ControlSession.new(supervisor, client)

    begin
      session.receive_data(%(not-a-command {})).should eq("404 Invalid command")
    ensure
      client.close rescue nil
      FileUtils.rm_rf(app_root)
    end
  end
end
