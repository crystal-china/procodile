module Procodile
  class TCPProxy
    def self.start(supervisor : Supervisor) : TCPProxy
      proxy = new(supervisor)
      proxy.start

      proxy
    end

    def initialize(@supervisor : Supervisor)
      @listeners = {} of TCPServer => Process
      @stopped_processes = [] of Process
      @sp_reader, @sp_writer = IO.pipe
      @reader_chan = Channel(Nil).new
      @tcpserver_chan = Channel(Nil).new
    end

    def start : Nil
      @supervisor.config.processes.each { |_, p| add_process(p) }

      spawn do
        listen
        Procodile.log nil, "proxy", "Stopped listening on all ports"
      end
    end

    private def add_process(process : Process) : Nil
      if process.proxy?
        address = process.proxy_address.not_nil!
        port = process.proxy_port.not_nil!

        @listeners[TCPServer.new(address, port)] = process

        Procodile.log nil, "proxy", "Proxying traffic on #{process.proxy_address}:#{process.proxy_port} to #{process.name}".colorize.green.to_s
        @sp_writer.puts(".")
      end
    rescue e : Exception
      Procodile.log nil, "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log nil, "proxy", e.backtrace[0, 5].join("\n")
    end

    def remove_process(process : Process) : Nil
      @stopped_processes << process
      @sp_writer.puts(".")
    end

    def listen : Nil
      spawn do
        loop do
          @sp_reader.read(Bytes.new(999)) rescue nil

          @reader_chan.send nil
        end
      end

      @listeners.keys.each do |tcpserver|
        spawn do
          loop do
            handle_client(tcpserver.accept, tcpserver)

            @tcpserver_chan.send nil
          end
        end
      end

      spawn do
        loop do
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

      spawn do
        loop do
          select
          when @reader_chan.receive
          when @tcpserver_chan.receive
          end
        end
      end
    rescue e
      Procodile.log nil, "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log nil, "proxy", e.backtrace[0, 5].join("\n")
    end

    def handle_client(client, server)
      process = @listeners[server]
      instances = @supervisor.processes[process]? || [] of Instance

      if instances.empty?
        Procodile.log nil, "proxy", "There are no processes running for #{process.name}"
      else
        instance = instances.sample

        # backend_socket = TCPSocket.new("127.0.0.1", instance.port)

        # if backend_socket.nil?
        #   Procodile.log nil, "proxy", "Could not connect to #{instance.description}:#{instance.port}"

        #   return
        # end

        readers = {client: client}

        readers.values.each do |io|
          spawn do
            loop do
              readers.keys.each do |key|
                p! io
                # next unless readers[key] == io
                # opposite_side = (key == :client) ? :backend : :client

                # Original ruby version code <==

                # if io.eof?
                #   readers[opposite_side].shutdown(Socket::SHUT_WR) rescue nil
                #   readers.delete(opposite_side)
                # else
                #   readers[opposite_side].write(io.readpartial(1024)) rescue nil
                # end

                # slice = Bytes.new(1024)
                # io.read(slice)
                # readers[opposite_side].write(slice) rescue nil
                # IO.copy io, readers[opposite_side], 1024 rescue nil
              end
              # sleep 0.1.seconds
            end
          end
        end
      end

      # rescue e
      #   Procodile.log nil, "proxy", "Exception: #{e.class}: #{e.message}"
      #   Procodile.log nil, "proxy", e.backtrace[0, 5].join("\n")
      # ensure
      #   backend_socket.close if backend_socket
      #   client.close if client
    end
  end
end
