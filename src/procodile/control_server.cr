require "socket"
require "./control_session"

module Procodile
  class ControlServer
    def self.start(supervisor) : Nil
      sock_path = supervisor.config.sock_path

      spawn do
        socket = UNIXServer.new(sock_path)

        Procodile.log nil, "control", "Listening at #{sock_path}"

        loop do
          client = socket.accept
          session = ControlSession.new(supervisor, client)
          line = client.gets

          while line
            if response = session.receive_data(line.strip)
              client.puts response
            end
          end
          client.close
        end
      end
    ensure
      FileUtils.rm_rf(sock_path.not_nil!)
    end
  end
end
