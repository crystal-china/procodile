module Procodile
  class CLI
    module LogCommand
      macro included
        options :log do |opts, cli|
          opts.on(
            "-f",
            "Wait for additional data and display it straight away"
          ) do
            cli.options.follow = true
          end

          opts.on(
            "-n LINES",
            "The number of previous lines to return"
          ) do |lines|
            cli.options.lines = lines.to_i
          end

          opts.on(
            "-p PROCESS",
            "--process PROCESS",
            "Show the log for a given process (rather than procodile)"
          ) do |process|
            cli.options.process = process
          end
        end
      end

      private def log : Nil
        if (process_opts = options.process)
          if (process = @config.processes[process_opts])
            log_path = process.log_path
          else
            raise Error.new "Invalid process name '#{process_opts}'"
          end
        else
          log_path = @config.log_path
        end

        if File.exists?(log_path)
          Tail::File.open(log_path) do |tail_file|
            if options.follow?
              tail_file.follow { |str| puts str }
            elsif (line_count = options.lines)
              tail_file.last_lines(line_count)
            else
              tail_file.last_lines
            end
          end
        else
          raise Error.new "No file found at #{log_path}"
        end
      end
    end
  end
end
