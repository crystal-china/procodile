require "socket"
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

    def listen : Nil
      puts "1"*100
      sock_path = @supervisor.config.sock_path
      server = UNIXServer.new(sock_path)

      Procodile.log nil, "control", "Listening at #{sock_path}"

      loop do
        client = server.accept
        session = ControlSession.new(@supervisor, client)

        while (line = client.gets)
          pp! line
          begin
            response = session.receive_data(line.strip)
          rescue Exception
            STDERR.puts "2"*100
            response = "200 ok"
          end
          pp! response
          if response
            client.puts response
          end
        end

        client.close
      end
    ensure
      FileUtils.rm_rf(sock_path) if sock_path
    end
  end
end
