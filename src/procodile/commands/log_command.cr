module Procodile
  class CLI
    module LogCommand
      macro included
        options :log do |opts, cli|
          opts.on("-f", "Wait for additional data and display it straight away") do
            cli.options.wait = true
          end

          opts.on("-n LINES", "The number of previous lines to return") do |lines|
            cli.options.lines = lines.to_i
          end

          opts.on("-p PROCESS", "--process PROCESS", "Show the log for a given process (rather than procodile)") do |process|
            cli.options.process = process
          end
        end
      end

      def log
        opts = [] of String
        opts << "-f" if options.wait
        opts << "-n #{options.lines}" if options.lines

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
          ::Process.exec("tail #{opts.join(' ')} #{log_path}", shell: true)
        else
          raise Error.new "No file found at #{log_path}"
        end
      end
    end
  end
end
