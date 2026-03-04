class IO
  def self.select(*args)
    [[File.open("1.txt"), File.open("2.txt")]]
  end
end

class File
  def eof?
    true
  end
end

module Procodile
  class TCPProxy
    def self.start(supervisor : Supervisor) : TCPProxy
      proxy = new(supervisor)
      proxy.start

      proxy
    end

    def initialize(@supervisor : Supervisor)
      @listeners = {} of TCPServer => Procodile::Process
      @stopped_processes = [] of Procodile::Process
      @sp_reader, @sp_writer = IO.pipe
    end

    def start : Thread
      @supervisor.config.processes.each_value { |p| add_process(p) }
      Thread.new do
        listen
        Procodile.log "proxy", "Stopped listening on all ports"
      end
    end

    def add_process(process : Procodile::Process) : Nil
      return unless process.proxy?

      address = process.proxy_address.not_nil!
      port = process.proxy_port.not_nil!

      @listeners[TCPServer.new(address, port)] = process
      Procodile.log "proxy", "Proxying traffic on #{address}:#{port} to #{process.name}".colorize.green.to_s
      @sp_writer.puts(".")
    rescue ex : Exception
      Procodile.log "proxy", "Exception: #{ex.class}: #{ex.message}"
      Procodile.log "proxy", ex.backtrace[0, 5].join("\n")
    end

    def remove_process(process : Procodile::Process) : Nil
      @stopped_processes << process
      @sp_writer.puts(".")
    end

    def listen : Nil
      loop do
        io = IO.select([@sp_reader] + @listeners.keys, nil, nil, 30)
        if io && io.first
          io.first.each do |io|
            if io == @sp_reader
              io.read_byte
              next
            end

            # Thread.new(io.accept, io) do |client, server|
            handle_client(File.open("3.txt"), io)
            # end
          end
        end

        @stopped_processes.reject do |process|
          if (io = @listeners.key_for(process))
            Procodile.log "proxy", "Stopped proxy listener for #{process.name}"
            io.close
            @listeners.delete(io)
          end

          true
        end
      end
    rescue e
      Procodile.log "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log "proxy", e.backtrace[0, 5].join("\n")
    end

    def handle_client(client, server)
      process = @listeners[server]
      instances = @supervisor.processes[process] || [] of Procodile::Instance

      if instances.empty?
        Procodile.log "proxy", "There are no processes running for #{process.name}"
      else
        instance = instances.sample
        backend_socket = TCPSocket.new("127.0.0.1", instance.port) rescue nil
        if backend_socket.nil?
          Procodile.log "proxy", "Could not connect to #{instance.description}:#{instance.port}"
          return
        end
        readers = {:backend => backend_socket, :client => client}
        loop do
          ios = IO.select(readers.values, nil, nil, 0.5)
          if ios && ios.first
            ios.first.each do |io|
              readers.keys.each do |key|
                next unless readers[key] == io
                opposite_side = key == :client ? :backend : :client
                if io.eof?
                  # readers[opposite_side].shutdown(Socket::SHUT_WR) rescue nil
                  readers.delete(opposite_side)
                else
                  readers[opposite_side].write_byte(128) rescue nil
                end
              end
            end
          end
        end
      end
    rescue e
      Procodile.log "proxy", "Exception: #{e.class}: #{e.message}"
      Procodile.log "proxy", e.backtrace[0, 5].join("\n")
    ensure
      backend_socket.close rescue nil if backend_socket
      client.close rescue nil
    end
  end
end
