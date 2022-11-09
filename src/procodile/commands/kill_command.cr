module Procodile
  class CLI
    module KillCommand
      macro included
        options :kill do |opts, cli|
        end
      end

      def kill
        Dir[File.join(@config.pid_root, "*.pid")].each do |pid_path|
          name = pid_path.split('/').last.rstrip(".pid")
          pid = File.read(pid_path).to_i
          begin
            ::Process.signal(Signal::INT, pid)
            puts "Sent KILL to #{pid} (#{name})"
          rescue RuntimeError
          end
          FileUtils.rm(pid_path)
        end
      end
    end
  end
end
