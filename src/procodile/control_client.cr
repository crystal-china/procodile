require "json"
require "socket"

module Procodile
  class ControlClient
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

    def self.run(sock_path : String, command : String, **options)
      socket = self.new(sock_path)
      socket.run(command, **options)
    ensure
      socket.try &.disconnect
    end

    def run(command, **options)
      @socket.puts("#{command} #{options.to_json}")

      if data = @socket.gets
        code, reply = data.strip.split(/\s+/, 2)
        if code.to_i == 200
          if reply && !reply.empty?
            case command
            when "start_processes", "stop"
              Array(InstanceConfig).from_json(reply)
            when "restart"
              Array(Tuple(InstanceConfig?, InstanceConfig?)).from_json(reply)
            when "check_concurrency"
              NamedTuple(started: Array(InstanceConfig), stopped: Array(InstanceConfig)).from_json(reply)
            when "status"
              ControlClientReplyForStatusCommand.from_json(reply)
            end
          else
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
