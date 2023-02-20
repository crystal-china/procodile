module Procodile
  class TCPProxy
    def self.start(supervisor)
      proxy = new(supervisor)
      proxy.start
      proxy
    end

    def initialize(@supervisor : Procodile::Supervisor)
      @listeners = {} of TCPServer => Procodile::Process
      @stopped_processes = [] of Procodile::Process
      @sp_reader, @sp_writer = IO.pipe
    end

    def start
      @supervisor.config.processes.each { |_, p| add_process(p) }
      spawn do
        listen
        Procodile.log nil, "proxy", "Stopped listening on all ports"
      end
    end

    def add_process(process)
      if process.proxy?
        @listeners[TCPServer.new(process.proxy_address.not_nil!, process.proxy_port.not_nil!)] = process
        Procodile.log nil, "proxy", "Proxying traffic on #{process.proxy_address}:#{process.proxy_port} to #{process.name}".color(32)
        @sp_writer.write(".".to_slice)
      end
    rescue e
      Procodile.log nil, "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log nil, "proxy", e.backtrace[0, 5].join("\n")
    end

    def remove_process(process)
      @stopped_processes << process
      @sp_writer.write(".".to_slice)
    end

    def listen
      sleep_chan = Channel(Nil).new
      sp_reader_chan = Channel(Nil).new
      listener_chan = Channel(Nil).new

      spawn do
        loop do
          sleep 30
          sleep_chan.send nil
        end
      end

      spawn do
        loop do
          @sp_reader.read(Bytes.new(999))
          sp_reader_chan.send nil
        end
      end

      @listeners.keys.each do |io|
        spawn do
          loop do
            handle_client(client: io.accept, server: io)
            listener_chan.send nil
          end
        end
      end

      loop do
        select
        when sp_reader_chan.receive
        when listener_chan.receive
        when sleep_chan.receive
        end

        @stopped_processes.reject do |process|
          if (io = @listeners.key_for(process))
            Procodile.log nil, "proxy", "Stopped proxy listener for #{process.name}"
            io.close
            @listeners.delete(io)
          end

          true
        end
      end
    end

    def handle_client(client, server)
      process = @listeners[server]
      instances = @supervisor.processes[process]? || [] of Procodile::Instance

      if instances.empty?
        Procodile.log nil, "proxy", "There are no processes running for #{process.name}"
      else
        instance = instances[rand(instances.size)]
        backend_socket = TCPSocket.new("127.0.0.1", instance.port) rescue nil
        if backend_socket.nil?
          Procodile.log nil, "proxy", "Could not connect to #{instance.description}:#{instance.port}"
          return
        end

        readers = {:backend => backend_socket, :client => client}
        sleep_chan = Channel(Nil).new
        readers_chan = Channel(Nil).new

        spawn do
          loop do
            sleep 0.5
            sleep_chan.send nil
          end
        end

        readers.values.each do |socket|
          spawn do
            loop do
              key = readers.key_for(socket)
              opposite_side = key == :client ? :backend : :client

              if socket.read_byte
                # readers[opposite_side].shutdown(Socket::SHUT_WR) rescue nil
                readers.delete(opposite_side)
              else
                readers[opposite_side].write(Bytes.new(socket.read(Bytes.new(1024)))) rescue nil
              end

              readers_chan.send nil
            end
          end
        end

        loop do
          select
          when readers_chan.receive
          when sleep_chan.receive
          end
        end
      end
    rescue e
      Procodile.log nil, "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log nil, "proxy", e.backtrace[0, 5].join("\n")
    ensure
      backend_socket.close if backend_socket
      client.close if client
    end
  end
end
