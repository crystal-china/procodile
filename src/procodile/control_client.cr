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
      # {
      #           :processes => nil,
      #     :stop_supervisor => nil
      # }
      @socket.puts("#{command} #{options.to_json}")

      pp! "#{command} #{options.to_json}"

      if data = @socket.gets
        puts data
        # 应该是这个样子。
        # "200 [{\"description\":\"test1.1\",\"pid\":791113,\"respawns\":0,\"status\":\"Stopping\",\"running\":false,\"started_at\":1668104019,\"tag\":null,\"port\":null},{\"description\":\"test2.1\",\"pid\":791117,\"respawns\":0,\"status\":\"Stopping\",\"running\":false,\"started_at\":1668104019,\"tag\":null,\"port\":null},{\"description\":\"test3.1\",\"pid\":791119,\"respawns\":0,\"status\":\"Stopping\",\"running\":false,\"started_at\":1668104019,\"tag\":null,\"port\":null},{\"description\":\"test4.1\",\"pid\":791121,\"respawns\":0,\"status\":\"Stopping\",\"running\":false,\"started_at\":1668104019,\"tag\":null,\"port\":null},{\"description\":\"test5.1\",\"pid\":791124,\"respawns\":0,\"status\":\"Stopping\",\"running\":true,\"started_at\":1668104019,\"tag\":null,\"port\":null}]\n"
        code, reply = data.strip.split(/\s+/, 2)
        if code.to_i == 200
          if reply && !reply.empty?
            case command
            when "start", "stop"
              Array(ControlClientReply).from_json(reply)
            when "restart"
              Array(Tuple(ControlClientReply, ControlClientReply)).from_json(reply)
            when "check_concurrency"
              NamedTuple(started: Array(ControlClientReply), stopped: Array(ControlClientReply)).from_json(reply)
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

    private def parse_response(data)
      code, message = data.split(/\s+/, 2)

      {code, message}
    end
  end
end
