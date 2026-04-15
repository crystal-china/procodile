require "../spec_helper"

private def free_tcp_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe Procodile::TCPProxy do
  it "forwards client traffic to a backend instance" do
    app_root = File.join("/tmp", "procodile-tcp-proxy-#{Random.rand(1_000_000)}")
    FileUtils.mkdir_p(app_root)
    FileUtils.mkdir_p(File.join(app_root, "pids"))

    backend_port = free_tcp_port
    proxy_port = free_tcp_port

    File.write(
      File.join(app_root, "backend.rb"),
      <<-'RUBY'
require "socket"
trap("TERM") { exit }
server = TCPServer.new("127.0.0.1", ENV.fetch("PORT").to_i)
loop do
  client = server.accept
  client.puts "pong"
  client.close
end
RUBY
    )

    File.write(
      File.join(app_root, "Procfile"),
      "app1: env -u RUBYOPT -u RUBYLIB ruby backend.rb\n"
    )

    File.write(
      File.join(app_root, "Procfile.local"),
      <<-YAML
app_name: proxy-test
pid_root: pids

processes:
  app1:
    allocate_port_from: #{backend_port}
    proxy_port: #{proxy_port}
    proxy_address: 127.0.0.1
YAML
    )

    config = Procodile::Config.new(root: app_root)
    run_options = Procodile::Supervisor::RunOptions.new(
      proxy: true,
      foreground: false
    )
    supervisor = Procodile::Supervisor.new(config, run_options)
    proxy = Procodile::TCPProxy.start(supervisor)

    instances = supervisor.start_processes(nil)
    instance = instances.first

    begin
      wait_until(5.seconds) { instance.running? }.should be_true

      response = nil
      wait_until(5.seconds, 100.milliseconds) do
        begin
          socket = TCPSocket.new("127.0.0.1", proxy_port)
          response = socket.gets
          socket.close
          !response.nil?
        rescue Socket::Error | IO::Error
          false
        end
      end.should be_true

      response.not_nil!.strip.should eq("pong")
    ensure
      instance.stop
      wait_until(5.seconds) { !instance.running? }
      instance.on_stop
      proxy.stop
      FileUtils.rm_rf(app_root)
    end
  end
end
