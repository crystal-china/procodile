require "./control_session"

module Procodile
  class ControlServer
    def self.start(supervisor : Supervisor) : Nil
      spawn do
        socket = self.new(supervisor)
        socket.listen
      rescue ex
        Procodile.log_exception("control", "Control server failed", ex)
      end
    end

    def initialize(@supervisor : Supervisor)
    end

    def listen : Nil
      sock_path = @supervisor.config.sock_path
      server = UNIXServer.new(sock_path)

      Procodile.log "control", "Listening at #{sock_path}"

      while (client = server.accept)
        session = ControlSession.new(@supervisor)

        spawn handle_client(session, client)
      end
    ensure
      FileUtils.rm_rf(sock_path) if sock_path
    end

    private def handle_client(session : ControlSession, client : UNIXSocket) : Nil
      while (line = client.gets)
        if (response = session.receive_data(line.strip))
          client.puts response
        end
      end
    rescue ex
      Procodile.log "control", "Error handling client: #{ex.class}: #{ex.message}"
    ensure
      client.close
    end
  end
end
