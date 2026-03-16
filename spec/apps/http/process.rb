#!/usr/bin/env ruby
require "socket"

port = Integer(ENV.fetch("PORT", "8080"))
server = TCPServer.new("0.0.0.0", port)

puts "listening on #{port}"

loop do
  client = server.accept

  begin
    req_line = client.gets
    headers = {}

    while (line = client.gets)
      line = line.chomp
      break if line.empty?
      k, v = line.split(":", 2)
      headers[k] = v.to_s.strip if k && v
    end

    method, path, _http = req_line.to_s.split(" ", 3)

    body =
      if path == "/ping"
        [
          "pong",
          "path=#{path}",
          "x-forwarded-for=#{headers['X-Forwarded-For']}",
          "x-real-ip=#{headers['X-Real-IP']}",
          "host=#{headers['Host']}"
        ].join("\n")
      else
        "ok"
      end

    client.write "HTTP/1.1 200 OK\r\n"
    client.write "Content-Type: text/plain\r\n"
    client.write "Content-Length: #{body.bytesize}\r\n"
    client.write "Connection: close\r\n"
    client.write "\r\n"
    client.write body
  rescue => e
    warn "error: #{e.class}: #{e.message}"
  ensure
    client.close
  end
end
