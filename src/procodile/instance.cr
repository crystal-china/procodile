require "./start_supervisor"
require "./supervisor"
require "./tcp_proxy"
require "lucky_env"

module Procodile
  class Instance
    @stopping_at : Time?
    @started_at : Time?
    @finished_at : Time?
    @failed_at : Time?
    @last_exit_status : Int32?
    @last_run_duration : Float64?

    property port : Int32?
    property process : Procodile::Process
    property pid : Int64?

    getter tag : String?
    getter id : Int32
    getter? stopped : Bool

    # Return a description for this instance
    getter description : String { "#{@process.name}.#{@id}" }

    def initialize(@supervisor : Supervisor, @process : Procodile::Process, @id : Int32)
      @respawns = 0
      @stopped = false
    end

    #
    # Start a new instance of this process
    #
    def start : Nil
      if stopping?
        Procodile.log(
          description,
          "Process is stopped/stopping therefore cannot be started again",
          @process.log_color
        )

        return
      end

      update_pid

      if running?
        Procodile.log(description, "Already running with PID #{@pid}", @process.log_color)

        return
      end

      port_allocations = @supervisor.run_options.port_allocations

      if port_allocations && (chosen_port = port_allocations[@process.name]?)
        if chosen_port == 0
          allocate_port
        else
          @port = chosen_port
          Procodile.log(description, "Assigned #{chosen_port} to process", @process.log_color)
        end
      elsif @process.proxy? && @supervisor.tcp_proxy
        # Allocate a port randomly if a proxy is needed
        allocate_port
      elsif (proposed_port = @process.allocate_port_from) && @process.restart_mode != "start-term"
        # Allocate ports to this process sequentially from the starting port
        process = @supervisor.processes[@process]?
        allocated_ports = process ? process.select(&.running?).map(&.port) : [] of Int32

        while !@port
          @port = proposed_port unless allocated_ports.includes?(proposed_port)
          proposed_port += 1
        end
      end

      if self.process.log_path && @supervisor.run_options.force_single_log? != true
        FileUtils.mkdir_p(File.dirname(self.process.log_path))
        log_destination = File.open(self.process.log_path, "a")
        io = nil
      else
        reader, writer = IO.pipe
        log_destination = writer
        io = reader
      end

      @tag = @supervisor.tag.dup if @supervisor.tag

      process = ::Process.new(
        ::Process.parse_arguments(@process.command),
        chdir: @process.config.root,
        env: environment_variables,
        output: log_destination,
        error: log_destination
      )

      spawn do
        begin
          status = process.wait
          @last_exit_status = status.exit_code?

          if @process.scheduled?
            if (started_at = @started_at)
              @last_run_duration = (Time.local - started_at).total_seconds
            end

            @supervisor.finish_scheduled_instance(self)
          end
        rescue ex
          Procodile.log_exception(description, "Process wait failed", ex)
        end
      end

      @pid = process.pid

      log_destination.close

      File.write(pid_file_path, "#{@pid}\n")

      @supervisor.add_instance(self, io)

      tag = @tag ? " (tagged with #{@tag})" : ""

      Procodile.log(
        description,
        "Started with PID #{@pid}#{tag}",
        @process.log_color
      )

      @supervisor.resolve_issue(:process_failed_permanently, @process.name) unless @process.scheduled?

      if self.process.log_path && io.nil?
        Procodile.log(
          description,
          "Logging to #{self.process.log_path}",
          @process.log_color
        )
      end

      @started_at = Time.local
      @finished_at = nil
      @process.last_started_at = @started_at
    rescue ex
      report_start_failure(ex.message.to_s)
      Procodile.log(
        description,
        "Failed to start: #{ex.message}",
        @process.log_color
      )
    ensure
      log_destination.close if log_destination && !log_destination.closed?
    end

    protected def report_start_failure(message : String) : Nil
      if @process.scheduled?
        @supervisor.report_issue(
          :scheduled_run_failed,
          @process.name,
          %|Scheduled process '#{@process.name}' failed to start: #{message} Fix it, \
then run `#{@process.config.suggested_command("restart -p #{@process.name}")}`.|
        )
      else
        @failed_at = Time.local

        @supervisor.report_issue(
          :process_failed_permanently,
          @process.name,
          %|Process '#{@process.name}' failed to start: #{message} Fix it, then \
run `#{@process.config.suggested_command("restart -p #{@process.name}")}`.|
        )
      end
    end

    private def daemon_process_hint : String
      return "" unless @last_exit_status == 0

      "This does not look like a long-running process.
If this command is meant to run once, it may not be suitable as a normal Procfile process."
    end

    #
    # Send this signal the signal to stop and mark the instance in a state that
    # tells us that we want it to be stopped.
    #
    def stop : Nil
      @stopping_at = Time.local

      update_pid

      if running?
        Procodile.log(
          description,
          "Sending #{@process.term_signal} to #{@pid}",
          @process.log_color
        )

        ::Process.signal(@process.term_signal, @pid.not_nil!)
      else
        Procodile.log(description, "Process already stopped", @process.log_color)
      end
    end

    #
    # Retarts the process using the appropriate method from the process configuration
    #
    # Why would this return self here?
    def restart(wg : WaitGroup) : self?
      restart_mode = @process.restart_mode

      Procodile.log(
        description,
        "Restarting using #{restart_mode} mode",
        @process.log_color
      )

      update_pid

      case restart_mode
      when Signal::USR1, Signal::USR2
        if running?
          ::Process.signal(restart_mode.as(Signal), @pid.not_nil!)

          @tag = @supervisor.tag if @supervisor.tag
          Procodile.log(
            description,
            "Sent #{restart_mode.to_s.upcase} signal to process #{@pid}",
            @process.log_color
          )
        else
          Procodile.log(
            description,
            "Process not running already, Starting it",
            @process.log_color
          )
          on_stop
          new_instance = @process.create_instance(@supervisor)
          new_instance.port = self.port
          new_instance.start
        end

        self
      when "start-term"
        new_instance = @process.create_instance(@supervisor)
        begin
          new_instance.start
        rescue ex : Error
          new_instance.report_start_failure(ex.message.to_s)

          Procodile.log(
            new_instance.description,
            "Failed to start during restart: #{ex.message}",
            @process.log_color
          )

          return nil
        end

        stop

        new_instance
      when "term-start"
        stop

        new_instance = @process.create_instance(@supervisor)
        new_instance.port = self.port

        wg.spawn do
          while running?
            sleep 0.5.seconds
          end

          @supervisor.remove_instance(self)

          begin
            new_instance.start
          rescue ex : Error
            new_instance.report_start_failure(ex.message.to_s)

            Procodile.log(
              new_instance.description,
              "Failed to start during restart: #{ex.message}",
              @process.log_color
            )
          end
        end

        new_instance
      end
    end

    #
    # Check the status of this process and handle as appropriate.
    #
    def check : Nil
      return if @process.scheduled?
      return if failed?

      # Everything is OK. The process is running.
      return true if running?

      # If the process isn't running any more, update the PID in our memory from
      # the file in case the process has changed itself.
      return check if update_pid

      if @supervisor.allow_respawning?
        if can_respawn?
          Procodile.log(
            description,
            "Process has stopped, Respawning...",
            @process.log_color
          )
          start
          add_respawn
        elsif respawns >= @process.max_respawns
          Procodile.log(
            description,
            "Warning:".colorize.light_gray.on_red.to_s +
            " this process has been respawned #{respawns} times and keeps dying".colorize.red.to_s,
            @process.log_color
          )

          Procodile.log(
            description,
            "It will not be respawned automatically any longer and will no longer be managed".colorize.red.to_s,
            @process.log_color
          )

          @supervisor.report_issue(
            :process_failed_permanently,
            @process.name,
            "Process '#{@process.name}' failed repeatedly and will not be respawned \
automatically. Fix it, then run `#{@process.config.suggested_command("restart -p #{@process.name}")}`.
#{daemon_process_hint}"
          )

          @failed_at = Time.local
          tidy
        end
      else
        Procodile.log(
          description,
          "Process has stopped, Respawning not available",
          @process.log_color
        )

        @supervisor.report_issue(
          :process_failed_permanently,
          @process.name,
          "Process '#{@process.name}' stopped and automatic respawning is disabled. \
Fix it, then run `#{@process.config.suggested_command("restart -p #{@process.name}")}`.
#{daemon_process_hint}"
        )

        @failed_at = Time.local
        tidy
      end
    end

    #
    # Return this instance as a hash
    #
    def to_struct : Instance::Config
      started_at = @started_at
      last_finished_at = @finished_at

      Instance::Config.new(
        description: self.description,
        pid: self.pid,
        respawns: self.respawns,
        status: self.status,
        started_at: started_at ? started_at.to_unix : nil,
        last_finished_at: last_finished_at ? last_finished_at.to_unix : nil,
        last_exit_status: @last_exit_status,
        last_run_duration: @last_run_duration,
        tag: self.tag,
        port: @port,
        foreground: @supervisor.run_use_foreground?
      )
    end

    #
    # Return the status of this instance
    #
    def status : Instance::Status
      if stopped?
        Instance::Status::Stopped
      elsif stopping?
        Instance::Status::Stopping
      elsif running?
        Instance::Status::Running
      elsif failed?
        Instance::Status::Failed
      else
        Instance::Status::Unknown
      end
    end

    #
    # Should this process be running?
    #
    def should_be_running? : Bool
      !(stopped? || stopping?)
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
    # Is this instance supposed to be stopping/be stopped?
    #
    def stopping? : Bool
      @stopping_at ? true : false
    end

    #
    # Has this failed?
    #
    def failed? : Bool
      @failed_at ? true : false
    end

    #
    # A method that will be called when this instance has been stopped and it isn't going to be
    # started again
    #
    def on_stop : Nil
      @started_at = nil
      @stopped = true

      tidy
    end

    def on_scheduled_finish : Nil
      @finished_at = Time.local
      @pid = nil
      @stopping_at = nil
      @failed_at = nil
      @process.last_finished_at = @finished_at
      @process.last_exit_status = @last_exit_status
      @process.last_run_duration = @last_run_duration

      tidy
    end

    #
    # Find a port number for this instance to listen on. We just check that nothing is already listening on it.
    # The process is expected to take it straight away if it wants it.
    #
    private def allocate_port(max_attempts : Int32 = 10) : Nil
      attempts = 0

      until @port
        attempts += 1
        possible_port = rand(20000..29999)

        if self.port_available?(possible_port)
          Procodile.log(
            description,
            "Allocated port as #{possible_port}",
            @process.log_color
          )
          @port = possible_port
        elsif attempts >= max_attempts
          raise Error.new "Couldn't allocate port for #{@process.name}"
        end
      end
    end

    #
    # Is the given port available?
    #
    private def port_available?(port : Int32) : Bool
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
        raise Error.new "Invalid network_protocol '#{@process.network_protocol}'"
      end
    rescue Socket::BindError
      false
    end

    #
    # Tidy up when this process isn't needed any more
    #
    private def tidy : Nil
      FileUtils.rm_rf(self.pid_file_path)
      Procodile.log(description, "Removed PID file", @process.log_color)
    end

    #
    # Increment the counter of respawns for this process
    #
    private def add_respawn : Int32
      last_respawn = @last_respawn

      if last_respawn && last_respawn < (Time.local - @process.respawn_window.seconds)
        @respawns = 1
      else
        @last_respawn = Time.local
        @respawns += 1
      end
    end

    #
    # Return the number of times this process has been respawned in the last hour
    #
    private def respawns : Int32
      last_respawn = @last_respawn

      if @respawns.nil? || last_respawn.nil? || last_respawn < @process.respawn_window.seconds.ago
        0
      else
        @respawns
      end
    end

    #
    # Can this process be respawned if needed?
    #
    private def can_respawn? : Bool
      !stopping? && (respawns + 1) <= @process.max_respawns
    end

    # Build the final environment for this instance by combining the process
    # environment and Procodile-managed instance variables.
    private def environment_variables : Hash(String, String)
      vars = @process.environment_variables(@supervisor)

      vars.merge({
        "PROC_NAME" => self.description,
        "PID_FILE"  => self.pid_file_path,
        "APP_ROOT"  => @process.config.root,
      })

      vars["PORT"] = @port.to_s if @port

      vars
    end

    #
    # Update the locally cached PID from that stored on the file system.
    #
    private def update_pid : Bool
      pid_from_file = self.pid_from_file

      if pid_from_file && pid_from_file != @pid
        @pid = pid_from_file
        @started_at = File.info(self.pid_file_path).modification_time

        Procodile.log(
          description,
          "PID file changed, Updated pid to #{@pid}",
          @process.log_color
        )
        true
      else
        false
      end
    end

    #
    # Return the path to this instance's PID file
    #
    private def pid_file_path : String
      File.join(@process.config.pid_root, "#{description}.pid")
    end

    #
    # Return the PID that is in the instances process PID file
    #
    private def pid_from_file : Int64?
      if File.exists?(pid_file_path)
        pid = File.read(pid_file_path)
        pid.blank? ? nil : pid.strip.to_i64
      end
    end
  end

  enum Instance::Status
    Unknown
    Stopped
    Stopping
    Running
    Failed
  end

  struct Instance::Config
    include JSON::Serializable

    getter description : String
    getter pid : Int64?
    getter respawns : Int32
    getter status : Instance::Status
    getter started_at : Int64?
    getter last_finished_at : Int64?
    getter last_exit_status : Int32?
    getter last_run_duration : Float64?
    getter tag : String?
    getter port : Int32?
    getter? foreground : Bool

    def initialize(
      @description : String,
      @pid : Int64?,
      @respawns : Int32,
      @status : Instance::Status,
      @started_at : Int64?,
      @last_finished_at : Int64?,
      @last_exit_status : Int32?,
      @last_run_duration : Float64?,
      @tag : String?,
      @port : Int32?,

      # foreground is used for supervisor, but add here for simplicity communication
      @foreground : Bool = false,
    )
    end
  end
end
