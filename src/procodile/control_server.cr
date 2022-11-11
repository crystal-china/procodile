require "socket"
require "./control_session"

module Procodile
  class ControlServer
    def self.start(supervisor) : Nil
      spawn do
        socket = ControlServer.new(supervisor)
        socket.listen
      end
    end

    def initialize(@supervisor : Procodile::Supervisor)
    end

    def listen : Nil
      socket = UNIXServer.new(@supervisor.config.sock_path)
      Procodile.log nil, "control", "Listening at #{@supervisor.config.sock_path}"
      loop do
        client = socket.accept
        session = ControlSession.new(@supervisor, client)
        while line = client.gets
          if response = session.receive_data(line.strip)
            client.puts response
          end
        end
        client.close
      end
    ensure
      FileUtils.rm_rf(@supervisor.config.sock_path)
    end
  end
end
