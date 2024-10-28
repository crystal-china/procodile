require "json"
require "socket"

module Procodile
  class ControlClient
    alias SocketResponse = Array(InstanceConfig) |
                           Array(Tuple(InstanceConfig?, InstanceConfig?)) |
                           NamedTuple(started: Array(InstanceConfig), stopped: Array(InstanceConfig)) |
                           ControlClientReplyForStatusCommand | Bool

    def self.run(sock_path : String, command : String, **options) : SocketResponse
      socket = self.new(sock_path)
      socket.run(command, **options)
    ensure
      socket.try &.disconnect
    end

    def initialize(sock_path, block : Proc(ControlClient, Nil)? = nil)
      @socket = UNIXSocket.new(sock_path)

      if block
        begin
          block.call(self)
        ensure
          disconnect
        end
      end
    end

    def run(command, **options) : SocketResponse
      @socket.puts("#{command} #{options.to_json}")

      if (data = @socket.gets)
        code, reply = data.strip.split(/\s+/, 2)

        if code.to_i == 200 && reply && !reply.empty?
          case command
          when "start_processes", "stop"
            Array(InstanceConfig).from_json(reply)
          when "restart"
            Array(Tuple(InstanceConfig?, InstanceConfig?)).from_json(reply)
          when "check_concurrency"
            NamedTuple(started: Array(InstanceConfig), stopped: Array(InstanceConfig)).from_json(reply)
          when "status"
            ControlClientReplyForStatusCommand.from_json(reply)
          else # e.g. reload command
            true
          end
        else
          raise Error.new "Error from control server: #{code} (#{reply.inspect})"
        end
      else
        raise Error.new "Control server disconnected."
      end
    end

    def disconnect : Nil
      @socket.try &.close
    end
  end
end
