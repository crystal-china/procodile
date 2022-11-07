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

    def self.run(sock_path, command, options = {} of Symbol => String)
      socket = self.new(sock_path)
      socket.run(command, options)
    ensure
      socket.try &.disconnect
    end

    def run(command, options = {} of String => String)
      @socket.puts("#{command} #{options.to_json}")
      if data = @socket.gets
        code, reply = data.strip.split(/\s+/, 2)
        if code.to_i == 200
          if reply && !reply.empty?
            JSON.parse(reply)
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

    def disconnect
      @socket.close rescue nil
    end

    private def parse_response(data)
      code, message = data.split(/\s+/, 2)
    end
  end
end
