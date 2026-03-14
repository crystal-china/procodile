module Procodile
  class TCPProxy
    @listeners = {} of Procodile::Process => TCPServer
    @mutex = Mutex.new

    def self.start(supervisor : Supervisor) : TCPProxy
      new(supervisor).start
    end

    def initialize(@supervisor : Supervisor)
    end

    def start : self
      sync_processes(@supervisor.config.processes.values)
      self
    end

    def stop : Nil
      servers = @mutex.synchronize do
        current = @listeners.values.dup
        @listeners.clear
        current
      end

      servers.each do |server|
        server.close rescue nil
      end
    end

    def sync_processes(processes : Array(Procodile::Process)) : Nil
      wanted = processes.select &.proxy?
      current = @mutex.synchronize { @listeners.keys.dup }

      (current - wanted).each { |process| remove_process(process) }
      wanted.each { |process| add_process(process) }
    end

    def remove_process(process : Procodile::Process) : Nil
      server = @mutex.synchronize { @listeners.delete(process) }

      return unless server

      Procodile.log "proxy", "Stopped proxy listener for #{process.name}"

      server.close rescue nil
    end

    def add_process(process : Procodile::Process) : Nil
      return unless process.proxy?

      address = process.proxy_address.not_nil!
      port = process.proxy_port.not_nil!
      existing = @mutex.synchronize { @listeners[process]? }

      unless existing.nil?
        local = existing.not_nil!.local_address # Socket::IPAddress

        return if local.address == address && local.port == port

        remove_process(process)
      end

      server = TCPServer.new(address, port)

      @mutex.synchronize { @listeners[process] = server }

      spawn accept_loop(process, server)

      Procodile.log "proxy", "Proxying traffic on #{address}:#{port} to #{process.name}".colorize.green.to_s
    rescue ex
      log_exception(ex)
    end

    private def accept_loop(process : Procodile::Process, server : TCPServer) : Nil
      loop do
        client = server.accept
        spawn handle_client(process, client)
      end
    rescue IO::Error | Socket::Error
      # Listener closed during shutdown or reconfiguration.
    rescue ex
      log_exception(ex)
    end

    private def handle_client(process : Procodile::Process, client : TCPSocket) : Nil
      instance = backend_instance_for(process)

      return Procodile.log "proxy", "There are no processes running for #{process.name}" if instance.nil?

      port = instance.port.not_nil!
      # 创建一个 TCPSocket 作为 client，连接监听在 port 上的我们实际管理的 process
      # 实际管理的 process 必须支持检测 $PORT 环境变量.
      backend = TCPSocket.new("127.0.0.1", port)

      WaitGroup.wait do |wg|
        wg.spawn { relay(client, backend) }
        wg.spawn { relay(backend, client) }
      end
    rescue Socket::ConnectError
      Procodile.log "proxy", "Could not connect to #{instance.try(&.description) || process.name}:#{instance.try(&.port)}"
    rescue ex
      log_exception(ex)
    ensure
      backend.close rescue nil if backend
      client.close rescue nil
    end

    private def backend_instance_for(process : Procodile::Process) : Instance?
      instances = @supervisor.processes[process]? || [] of Instance
      instances = instances.select { |instance| !instance.stopping? && !instance.port.nil? }

      return nil if instances.empty?

      instances.sample
    end

    private def relay(input : IO, output : IO) : Nil
      buffer = Bytes.new(4096)
      loop do
        bytes = input.read(buffer)
        break if bytes == 0
        output.write(buffer[0, bytes])
      end
    rescue IO::Error
      # Peer closed while relaying.
    end

    private def log_exception(ex : Exception) : Nil
      Procodile.log "proxy", "Exception: #{ex.class}: #{ex.message}"
      if (bt = ex.backtrace)
        Procodile.log "proxy", bt.first(5).join("\n")
      end
    end
  end
end
