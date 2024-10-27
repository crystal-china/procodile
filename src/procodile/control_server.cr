require "socket"
require "./control_session"

module Procodile
  class ControlServer
    @supervisor : Procodile::Supervisor

    def initialize(@supervisor)
    end

    def listen
      sock_path = @supervisor.config.sock_path

      server = UNIXServer.new(sock_path)

      Procodile.log nil, "control", "Listening at #{sock_path}"

      loop do
        client = server.accept
        session = ControlSession.new(@supervisor, client)

        while (line = client.gets)
          if (response = session.receive_data(line.strip))
            client.puts response
          end
        end

        client.close
      end
    ensure
      FileUtils.rm_rf(sock_path.not_nil!)
    end

    def self.start(supervisor)
      spawn do
        socket = self.new(supervisor)
        socket.listen
      end
    end
  end
end
