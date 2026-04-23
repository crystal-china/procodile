require "./status_types"

module Procodile
  class ControlClient
    def self.start_processes(sock_path : String, process_names : Array(String)? = nil, tag : String? = nil, port_allocations : Hash(String, Int32)? = nil) : StartProcessesResponse
      options = ControlHandler::Options.new(
        process_names: process_names,
        tag: tag,
        port_allocations: port_allocations
      )

      send_request(sock_path, "start_processes", options) do |reply|
        StartProcessesResponse.from_json(reply)
      end
    end

    def self.stop(sock_path : String, process_names : Array(String)? = nil, stop_supervisor : Bool? = nil) : StopProcessesResponse
      options = ControlHandler::Options.new(
        process_names: process_names,
        stop_supervisor: stop_supervisor
      )

      send_request(sock_path, "stop", options) do |reply|
        StopProcessesResponse.from_json(reply)
      end
    end

    def self.restart(sock_path : String, process_names : Array(String)? = nil, tag : String? = nil) : RestartProcessesResponse
      options = ControlHandler::Options.new(
        process_names: process_names,
        tag: tag
      )

      send_request(sock_path, "restart", options) do |reply|
        RestartProcessesResponse.from_json(reply)
      end
    end

    def self.reload_config(sock_path : String) : OkResponse
      send_request(sock_path, "reload_config", ControlHandler::Options.new) do |reply|
        OkResponse.from_json(reply)
      end
    end

    def self.check_concurrency(sock_path : String, reload : Bool? = nil) : CheckConcurrencyResponse
      options = ControlHandler::Options.new(reload: reload)

      send_request(sock_path, "check_concurrency", options) do |reply|
        CheckConcurrencyResponse.from_json(reply)
      end
    end

    def self.status(sock_path : String) : StatusReply
      send_request(sock_path, "status", ControlHandler::Options.new) do |reply|
        StatusReply.from_json(reply)
      end
    end

    private def self.send_request(
      sock_path : String,
      command : String,
      options : ControlHandler::Options,
      &decoder : String -> T
    ) : T forall T
      socket = UNIXSocket.new(sock_path)
      socket.puts("#{command} #{options.to_json}")

      if (data = socket.gets)
        code, reply = data.strip.split(/\s+/, 2)

        if code.to_i == 200 && reply
          decoder.call(reply)
        elsif code.to_i == 500 && reply
          message = begin
            String.from_json(reply)
          rescue JSON::ParseException
            reply
          end

          raise Error.new(message)
        else
          raise Error.new "Error from control server: #{code}: (#{reply.inspect})"
        end
      else
        raise Error.new "Control server disconnected. Check procodile.log for details."
      end
    ensure
      socket.try &.close
    end
  end
end
