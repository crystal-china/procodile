module Procodile
  class CLI
    module StatusCommand
      macro included
        options :status do |opts, cli|
          opts.on(
            "--json",
            "Return the status as a JSON hash"
          ) do
            cli.options.json = true
          end

          opts.on(
            "--json-pretty",
            "Return the status as a JSON hash printed nicely"
          ) do
            cli.options.json_pretty = true
          end

          opts.on(
            "--simple",
            "Return overall status"
          ) do
            cli.options.simple = true
          end
        end
      end

      private def status : Nil
        if !supervisor_running?
          if @options.simple?
            puts "NotRunning || Procodile supervisor isn't running"

            return
          else
            raise Error.new "Procodile supervisor isn't running"
          end
        end

        status = status_reply

        case @options
        when .json?
          puts status.to_json
        when .json_pretty?
          puts status
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
            puts " * #{message}".colorize.red
          end
        end
      end

      private def print_processes(status : ControlClient::ReplyOfStatusCommand) : Nil
        puts

        failed_processes = status.runtime_issues.each_with_object(Set(String).new) do |issue, set|
          next unless issue.type.process_failed_permanently?

          set << issue.process_name
        end

        status.processes.each_with_index do |process, index|
          port = process.proxy_port ? "#{process.proxy_address}:#{process.proxy_port}" : "none"
          instances = status.instances[process.name]
          scheduled = !process.schedule.nil?

          puts unless index == 0
          puts "|| #{process.name}".colorize(process.log_color)
          puts "#{"||".colorize(process.log_color)} Command             #{process.command}"
          puts "#{"||".colorize(process.log_color)} Log path            #{process.log_path || "none specified"}"

          if scheduled
            schedule = process.schedule.not_nil!
            puts "#{"||".colorize(process.log_color)} Schedule            #{schedule}"
            puts "#{"||".colorize(process.log_color)} Last Started At     #{formatted_timestamp(process.last_started_at)}" if process.last_started_at
            puts "#{"||".colorize(process.log_color)} Last Finished At    #{formatted_timestamp(process.last_finished_at)}" if process.last_finished_at
            puts "#{"||".colorize(process.log_color)} Last Exit Status    #{process.last_exit_status}" unless process.last_exit_status.nil?
            puts "#{"||".colorize(process.log_color)} Last Run Duration   #{formatted_duration(process.last_run_duration)}" if process.last_run_duration
          else
            puts "#{"||".colorize(process.log_color)} Quantity            #{process.quantity}"
            puts "#{"||".colorize(process.log_color)} Respawning          #{process.max_respawns} every #{process.respawn_window} seconds"
            puts "#{"||".colorize(process.log_color)} Restart mode        #{process.restart_mode}"
            puts "#{"||".colorize(process.log_color)} Address/Port        #{port}"
          end

          if process.removed? && instances.any?(&.status.running?)
            puts "#{"||".colorize(process.log_color)} Status              Removed from Procfile, still running"
          end

          if instances.empty?
            if scheduled
              puts "#{"||".colorize(process.log_color)} No scheduled runs in progress."
            elsif failed_processes.includes?(process.name)
              puts "#{"||".colorize(process.log_color)} Failed to start."
            else
              puts "#{"||".colorize(process.log_color)} No processes running."
            end
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
          timestamp.to_s("%Y-%m-%d")
        end
      end

      private def formatted_duration(duration : Float64?) : String
        return "" if duration.nil?

        total_milliseconds = (duration * 1000).round.to_i64
        total_seconds = total_milliseconds // 1000

        hours = total_seconds // 3600
        minutes = (total_seconds % 3600) // 60
        seconds = total_seconds % 60
        milliseconds = total_milliseconds % 1000

        if hours > 0
          "#{hours}h#{minutes}m#{seconds}s"
        elsif minutes > 0
          "#{minutes}m#{seconds}s"
        elsif seconds > 0
          milliseconds > 0 ? "#{seconds}.#{milliseconds.to_s.rjust(3, '0')}s" : "#{seconds}s"
        else
          "#{milliseconds}ms"
        end
      end
    end
  end
end
