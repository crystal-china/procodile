module Procodile
  class CLI
    module StatusCommand
      macro included
        options :status do |opts, cli|
          opts.on("--json", "Return the status as a JSON hash") do
            cli.options.json = true
          end

          opts.on("--json-pretty", "Return the status as a JSON hash printed nicely") do
            cli.options.json_pretty = true
          end

          opts.on("--simple", "Return overall status") do
            cli.options.simple = true
          end
        end
      end

      private def status : Nil
        if supervisor_running?
          status = ControlClient.run(
            @config.sock_path, "status"
          ).as ControlClient::ReplyOfStatusCommand

          case @options
          when .json?
            puts status.to_json
          when .json_pretty?
            puts status
            nil
          when .simple?
            if status.messages.empty?
              message = status.instances.map { |p, i| "#{p}[#{i.size}]" }

              puts "OK || #{message.join(", ")}"
            else
              message = status.messages.join(", ")
              puts "Issues || #{message}"
            end
          else
            print_header(status)
            print_processes(status)
          end
        else
          if @options.simple?
            puts "NotRunning || Procodile supervisor isn't running"
          else
            raise Error.new "Procodile supervisor isn't running"
          end
        end
      end

      private def print_header(status : ControlClient::ReplyOfStatusCommand) : Nil
        puts "Procodile Version   #{status.version.colorize.blue}"
        puts "Application Root    #{status.root.colorize.blue}"
        puts "Supervisor PID      #{(status.supervisor["pid"]).to_s.colorize.blue}"

        if (time = status.supervisor["started_at"])
          time = Time.unix(time)
          puts "Started             #{time.to_s.colorize.blue}"
        end

        if !status.environment_variables.empty?
          status.environment_variables.each_with_index do |(key, value), index|
            if index == 0
              print "Environment Vars    "
            else
              print "                    "
            end
            print key.colorize.blue
            puts " #{value}"
          end
        end

        unless status.messages.empty?
          puts
          status.messages.each do |message|
            puts "\e[31m * #{message}\e[0m"
          end
        end
      end

      private def print_processes(status : Procodile::ControlClient::ReplyOfStatusCommand) : Nil
        puts

        status.processes.each_with_index do |process, index|
          port = process.proxy_port ? "#{process.proxy_address}:#{process.proxy_port}" : "none"
          instances = status.instances[process.name]

          puts unless index == 0
          puts "|| #{process.name}".colorize(process.log_color)
          puts "#{"||".colorize(process.log_color)} Quantity            #{process.quantity}"
          puts "#{"||".colorize(process.log_color)} Command             #{process.command}"
          puts "#{"||".colorize(process.log_color)} Respawning          #{process.max_respawns} every #{process.respawn_window} seconds"
          puts "#{"||".colorize(process.log_color)} Restart mode        #{process.restart_mode}"
          puts "#{"||".colorize(process.log_color)} Log path            #{process.log_path || "none specified"}"
          puts "#{"||".colorize(process.log_color)} Address/Port        #{port}"

          if instances.empty?
            puts "#{"||".colorize(process.log_color)} No processes running."
          else
            instances.each do |instance|
              print "|| => #{instance.description.ljust(17, ' ')}".colorize(process.log_color)
              print instance.status.to_s.ljust(10, ' ')
              print "   #{formatted_timestamp(instance.started_at).ljust(10, ' ')}"
              print "   pid:#{instance.pid.to_s.ljust(6, ' ')}"
              print "   respawns:#{instance.respawns.to_s.ljust(4, ' ')}"
              print "   port:#{(instance.port || '-').to_s.ljust(6, ' ')}"
              print "   tag:#{instance.tag || '-'}"
              puts
            end
          end
        end
      end

      private def formatted_timestamp(timestamp : Int64?) : String
        return "" if timestamp.nil?

        timestamp = Time.unix(timestamp)

        if timestamp > 1.day.ago
          timestamp.to_s("%H:%M")
        else
          timestamp.to_s("%d/%m/%Y")
        end
      end

      def self.parse(message : Supervisor::Message) : String
      end
    end
  end
end
