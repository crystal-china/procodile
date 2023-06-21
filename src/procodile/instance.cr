require "./supervisor"

module Procodile
  class Instance
    @started_at : Time?
    @supervisor : Procodile::Supervisor
    @process : Procodile::Process
    @id : Int32
    @stopping : Time?
    @pid : Int64
    @port : Int32?
    @tag : String?

    property :pid, :process, :port
    getter :id, :tag

    def initialize(@supervisor, @process, @id)
      @respawns = 0
      @started_at = nil
      @pid = uninitialized Int32
    end

    #
    # Return a description for this instance
    #
    def description
      "#{@process.name}.#{@id}"
    end

    #
    # Return the status of this instance
    #
    def status : String
      if stopped?
        "Stopped"
      elsif stopping?
        "Stopping"
      elsif running?
        "Running"
      elsif failed?
        "Failed"
      else
        "Unknown"
      end
    end

    #
    # Should this process be running?
    #
    def should_be_running? : Bool
      !(stopped? || stopping?)
    end

    #
    # Return an array of environment variables that should be set
    #
    def environment_variables : Hash(String, String)
      vars = @process.environment_variables.merge({
        "PROC_NAME" => self.description,
        "PID_FILE"  => self.pid_file_path,
        "APP_ROOT"  => @process.config.root,
      })
      vars["PORT"] = @port.to_s if @port

      vars
    end

    #
    # Return the path to this instance's PID file
    #
    def pid_file_path : String
      File.join(@process.config.pid_root, "#{description}.pid")
    end

    #
    # Return the PID that is in the instances process PID file
    #
    def pid_from_file : Int64?
      if File.exists?(pid_file_path)
        pid = File.read(pid_file_path)
        pid.empty? ? nil : pid.strip.to_i64
      end
    end

    #
    # Is this process running? Pass an option to check the given PID instead of the instance
    #
    def running? : Bool
      if (pid = @pid)
        ::Process.pgid(pid) ? true : false
      else
        false
      end
    rescue RuntimeError
      false
    end

    #
    # Start a new instance of this process
    #
    def start
      if stopping?
        Procodile.log(@process.log_color, description, "Process is stopped/stopping therefore cannot be started again.")
        return false
      end

      update_pid

      if running?
        Procodile.log(@process.log_color, description, "Already running with PID #{@pid}")
        nil
      else
        port_allocations = @supervisor.run_options.port_allocations

        #         {
        #              :respawn => nil,
        #       :stop_when_none => nil,
        #                :proxy => nil,
        #     :force_single_log => nil,
        #     :port_allocations => nil
        # }

        if port_allocations && (chosen_port = port_allocations[@process.name]?)
          if chosen_port == 0
            allocate_port
          else
            @port = chosen_port
            Procodile.log(@process.log_color, description, "Assigned #{chosen_port} to process")
          end
        elsif (proposed_port = @process.allocate_port_from) && @process.restart_mode != "start-term"
          # Allocate ports to this process sequentially from the starting port
          process = @supervisor.processes[@process]

          allocated_ports = process ? process.select(&.running?).map(&.port) : [] of Int32

          until @port
            unless allocated_ports.includes?(proposed_port)
              @port = proposed_port
            end
            proposed_port += 1
          end
        end

        if self.process.log_path && @supervisor.run_options.force_single_log != true
          FileUtils.mkdir_p(File.dirname(self.process.log_path))
          log_destination = File.open(self.process.log_path, "a")
          io = nil
        else
          reader, writer = IO.pipe
          log_destination = writer
          io = reader
        end
        @tag = @supervisor.tag.dup if @supervisor.tag
        Dir.cd(@process.config.root)

        commands = @process.command.split(" ")

        process = ::Process.new(
          command: commands[0],
          args: commands[1..],
          env: environment_variables,
          output: log_destination,
          error: log_destination
        )

        @pid = process.pid

        log_destination.close
        File.write(pid_file_path, "#{@pid}\n")
        @supervisor.add_instance(self, io)

        spawn { process.wait }

        Procodile.log(@process.log_color, description, "Started with PID #{@pid}" + (@tag ? " (tagged with #{@tag})" : ""))
        if self.process.log_path && io.nil?
          Procodile.log(@process.log_color, description, "Logging to #{self.process.log_path}")
        end
        @started_at = Time.local
      end
    end

    #
    # Is this instance supposed to be stopping/be stopped?
    #
    def stopping? : Bool
      @stopping ? true : false
    end

    #
    # Is this stopped?
    #
    def stopped? : Bool
      @stopped || false
    end

    #
    # Has this failed?
    #
    def failed? : Bool
      @failed ? true : false
    end

    #
    # Send this signal the signal to stop and mark the instance in a state that
    # tells us that we want it to be stopped.
    #
    def stop
      @stopping = Time.local
      update_pid

      if self.running?
        Procodile.log(@process.log_color, description, "Sending #{@process.term_signal} to #{@pid}")
        ::Process.signal(@process.term_signal, pid.not_nil!)
      else
        Procodile.log(@process.log_color, description, "Process already stopped")
      end
    end

    #
    # A method that will be called when this instance has been stopped and it isn't going to be
    # started again
    #
    def on_stop
      @started_at = nil
      @stopped = true
      tidy
    end

    #
    # Tidy up when this process isn't needed any more
    #
    def tidy
      FileUtils.rm_rf(self.pid_file_path)
      Procodile.log(@process.log_color, description, "Removed PID file")
    end

    #
    # Retarts the process using the appropriate method from the process configuration
    #
    def restart : self?
      restart_mode = @process.restart_mode

      Procodile.log(@process.log_color, description, "Restarting using #{restart_mode} mode")

      update_pid

      case restart_mode
      when Signal::USR1, Signal::USR2
        if running?
          ::Process.signal(restart_mode.as(Signal), @pid)
          @tag = @supervisor.tag if @supervisor.tag
          Procodile.log(@process.log_color, description, "Sent #{restart_mode.to_s.upcase} signal to process #{@pid}")
        else
          Procodile.log(@process.log_color, description, "Process not running already. Starting it.")
          on_stop
          new_instance = @process.create_instance(@supervisor)
          new_instance.port = self.port
          new_instance.start
        end
        self
      when "start-term"
        new_instance = @process.create_instance(@supervisor)
        new_instance.start
        stop
        new_instance
      when "term-start"
        stop
        new_instance = @process.create_instance(@supervisor)
        new_instance.port = self.port

        spawn do
          while running?
            sleep 0.5
          end
          new_instance.start
        end

        new_instance
      end
    end

    #
    # Update the locally cached PID from that stored on the file system.
    #
    def update_pid : Bool
      pid_from_file = self.pid_from_file
      if pid_from_file && pid_from_file != @pid
        @pid = pid_from_file
        @started_at = File.info(self.pid_file_path).modification_time
        Procodile.log(@process.log_color, description, "PID file changed. Updated pid to #{@pid}")
        true
      else
        false
      end
    end

    #
    # Check the status of this process and handle as appropriate.
    #
    def check(options = {} of String => String)
      return if failed?

      if self.running?
        # Everything is OK. The process is running.
        true
      else
        # If the process isn't running any more, update the PID in our memory from
        # the file in case the process has changed itself.
        return check if update_pid

        if @supervisor.allow_respawning?
          if can_respawn?
            Procodile.log(@process.log_color, description, "Process has stopped. Respawning...")
            start
            add_respawn
          elsif respawns >= @process.max_respawns
            Procodile.log(@process.log_color, description, "\e[41;37mWarning:\e[0m\e[31m this process has been respawned #{respawns} times and keeps dying.\e[0m")
            Procodile.log(@process.log_color, description, "It will not be respawned automatically any longer and will no longer be managed.".color(31))
            @failed = Time.local
            tidy
          end
        else
          Procodile.log(@process.log_color, description, "Process has stopped. Respawning not available.")
          @failed = Time.local
          tidy
        end
      end
    end

    #
    # Can this process be respawned if needed?
    #
    def can_respawn? : Bool
      !stopping? && (respawns + 1) <= @process.max_respawns
    end

    #
    # Return the number of times this process has been respawned in the last hour
    #
    def respawns : Int32
      last_respawn = @last_respawn

      if @respawns.nil? || last_respawn.nil? || last_respawn < (Time.local - @process.respawn_window.seconds)
        0
      else
        @respawns
      end
    end

    #
    # Increment the counter of respawns for this process
    #
    def add_respawn : Int32
      last_respawn = @last_respawn

      if last_respawn && last_respawn < (Time.local - @process.respawn_window.seconds)
        @respawns = 1
      else
        @last_respawn = Time.local
        @respawns += 1
      end
    end

    #
    # Return this instance as a hash
    #
    def to_hash
      started_at = @started_at

      InstanceConfig.new(
        description: self.description,
        pid: self.pid,
        respawns: self.respawns,
        status: self.status,
        running: self.running?,
        started_at: started_at ? started_at.to_unix : nil,
        tag: self.tag,
        port: @port,
      )
    end

    #
    # Find a port number for this instance to listen on. We just check that nothing is already listening on it.
    # The process is expected to take it straight away if it wants it.
    #
    def allocate_port(max_attempts = 10)
      attempts = 0

      until @port
        attempts += 1
        possible_port = rand(20000..29999)

        if self.port_available?(possible_port)
          Procodile.log(@process.log_color, description, "Allocated port as #{possible_port}")
          @port = possible_port
        elsif attempts >= max_attempts
          raise Procodile::Error.new "Couldn't allocate port for #{process.name}"
        end
      end
    end

    #
    # Is the given port available?
    #
    def port_available?(port) : Bool
      case @process.network_protocol
      when "tcp"
        server = TCPServer.new("127.0.0.1", port)
        server.close
        true
      when "udp"
        server = UDPSocket.new
        server.bind("127.0.0.1", port)
        server.close
        true
      else
        raise Procodile::Error.new "Invalid network_protocol '#{@process.network_protocol}'"
      end
    rescue Socket::BindError
      false
    end
  end
end
