require "./control_session"

module Procodile
  class ControlServer
    @supervisor : Procodile::Supervisor

    def self.start(supervisor : Procodile::Supervisor) : Nil
      spawn do
        socket = self.new(supervisor)
        socket.listen
      end
    end

    def initialize(@supervisor)
    end

    def handle_client(session, client)
      while (line = client.gets)
        if (response = session.receive_data(line.strip))
          client.puts response
        end
      end
    end

    def listen : Nil
      sock_path = @supervisor.config.sock_path
      server = UNIXServer.new(sock_path)

      Procodile.log nil, "control", "Listening at #{sock_path}"

      while (client = server.accept)
        session = ControlSession.new(@supervisor, client)

        spawn handle_client(session, client)
      end
    ensure
      FileUtils.rm_rf(sock_path) if sock_path
    end
  end
end
