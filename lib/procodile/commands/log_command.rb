module Procodile
  class CLI
    module LogCommand
      def self.included(base)
        base.class_eval do
          desc "Open/stream a Procodile log file"
          options do |opts, cli|
            opts.on("-f", "Wait for additional data and display it straight away") do
              cli.options[:wait] = true
            end

            opts.on("-n LINES", "The number of previous lines to return") do |lines|
              cli.options[:lines] = lines.to_i
            end

            opts.on("-p PROCESS", "--process PROCESS", "Show the log for a given process (rather than procodile)") do |process|
              cli.options[:process] = process
            end
          end
          command def log
            opts = []
            opts << "-f" if options[:wait]
            opts << "-n #{options[:lines]}" if options[:lines]

            if options[:process]
              if process = @config.processes[options[:process]]
                log_path = process.log_path
              else
                raise Error, "Invalid process name '#{options[:process]}'"
              end
            else
              log_path = @config.log_path
            end
            if File.exist?(log_path)
              exec("tail #{opts.join(' ')} #{log_path}")
            else
              raise Error, "No file found at #{log_path}"
            end
          end
        end
      end
    end
  end
end
