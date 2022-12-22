require "./control_server"
require "./tcp_proxy"
require "./signal_handler"

module Procodile
  class Supervisor
    @tag : String?
    @tcp_proxy : Procodile::TCPProxy?

    getter config, processes, started_at, tag, tcp_proxy, run_options

    def initialize(@config : Procodile::Config, @run_options = Procodile::RunOptions.new)
      @processes = {} of Procodile::Process => Array(Procodile::Instance)
      @readers = {} of IO::FileDescriptor => Procodile::Instance

      @signal_handler = SignalHandler.new
      @signal_handler.register(Signal::TERM) { stop_supervisor }
      @signal_handler.register(Signal::INT) { stop(SupervisorOptions.new(stop_supervisor: true)) }
      @signal_handler.register(Signal::USR1) { restart }
      @signal_handler.register(Signal::USR2) { }
      @signal_handler.register(Signal::HUP) { reload_config }
    end

    def allow_respawning? : Bool
      @run_options.respawn != false
    end

    def start(after_start : Proc(Procodile::Supervisor, Nil))
      Procodile.log nil, "system", "Procodile supervisor started with PID #{::Process.pid}"
      Procodile.log nil, "system", "Application root is #{@config.root}"

      if @run_options.respawn == false
        Procodile.log nil, "system", "Automatic respawning is disabled"
      end

      ControlServer.start(self)

      if @run_options.proxy
        Procodile.log nil, "system", "Proxy is enabled"
        @tcp_proxy = TCPProxy.start(self)
      end

      watch_for_output

      @started_at = Time.local

      # 这里调用的是 supervisor.start_processes
      after_start.call(self)
    rescue e
      Procodile.log nil, "system", "Error: #{e.class} (#{e.message})"
      e.backtrace.each { |bt| Procodile.log nil, "system", "=> #{bt})" }
      stop(SupervisorOptions.new(stop_supervisor: true))
    ensure
      loop { supervise; sleep 3 }
    end

    def start_processes(process_names : Array(String)?, options = SupervisorOptions.new) : Array(Procodile::Instance)
      @tag = options.tag

      reload_config

      instances_started = [] of Procodile::Instance

      @config.processes.each do |name, process|
        next if process_names && !process_names.includes?(name.to_s) # Not a process we want
        next if @processes[process]? && !@processes[process].empty?  # Process type already running

        instances = process.generate_instances(self)
        instances.each &.start
        instances_started.concat instances
      end

      instances_started
    end

    def stop(options = SupervisorOptions.new) : Array(Procodile::Instance)
      if options.stop_supervisor
        @run_options.stop_when_none = true
      end

      reload_config

      processes = options.processes
      instances_stopped = [] of Procodile::Instance

      if processes.nil?
        Procodile.log nil, "system", "Stopping all #{@config.app_name} processes"
        @processes.each do |_, instances|
          instances.each do |instance|
            instance.stop
            instances_stopped << instance
          end
        end
      else
        instances = process_names_to_instances(processes)
        Procodile.log nil, "system", "Stopping #{instances.size} process(es)"
        instances.each do |instance|
          instance.stop
          instances_stopped << instance
        end
      end

      instances_stopped
    end

    def restart(options = SupervisorOptions.new)
      @tag = options.tag

      reload_config

      instances_restarted = [] of Array(Procodile::Instance?)

      processes = options.processes

      if processes.nil?
        Procodile.log nil, "system", "Restarting all #{@config.app_name} processes"
        instances = @processes.values.flatten
      else
        instances = process_names_to_instances(processes)
        Procodile.log nil, "system", "Restarting #{instances.size} process(es)"
      end

      # Stop any processes that are no longer wanted at this point
      stopped = check_instance_quantities(:stopped, processes)[:stopped].map { |i| [i, nil] }
      instances_restarted.concat stopped

      instances.each do |instance|
        next if instance.stopping?

        new_instance = instance.restart
        instances_restarted << [instance, new_instance]
      end

      # Start any processes that are needed at this point
      checked = check_instance_quantities(:started, processes)[:started].map { |i| [nil, i] }
      instances_restarted.concat checked

      instances_restarted
    end

    def stop_supervisor
      Procodile.log nil, "system", "Stopping Procodile supervisor"
      FileUtils.rm_rf(File.join(@config.pid_root, "procodile.pid"))
      ::Process.exit 0
    end

    def supervise
      # Tell instances that have been stopped that they have been stopped
      remove_stopped_instances

      # Remove removed processes
      remove_removed_processes

      # Check all instances that we manage and let them do their things.
      @processes.each do |_, instances|
        instances.each(&.check)
      end

      # If the processes go away, we can stop the supervisor now
      if @run_options.stop_when_none && @processes.all? { |_, instances| instances.reject(&.failed?).empty? }
        Procodile.log nil, "system", "All processes have stopped"
        stop_supervisor
      end
    end

    def reload_config
      Procodile.log nil, "system", "Reloading configuration"
      @config.reload
    end

    def check_concurrency(options = {} of String => String) : Hash(Symbol, Array(Procodile::Instance))
      Procodile.log nil, "system", "Checking process concurrency"
      reload_config unless options.reload == false

      result = check_instance_quantities

      if result[:started].empty? && result[:stopped].empty?
        Procodile.log nil, "system", "Process concurrency looks good"
      else
        unless result[:started].empty?
          Procodile.log nil, "system", "Concurrency check started #{result[:started].map(&.description).join(", ")}"
        end

        unless result[:stopped].empty?
          Procodile.log nil, "system", "Concurrency check stopped #{result[:stopped].map(&.description).join(", ")}"
        end
      end

      result
    end

    def to_hash
      {
        started_at: @started_at.not_nil!.to_unix,
        pid:        ::Process.pid,
      }
    end

    def messages : Array(SupervisorMessages)
      messages = [] of SupervisorMessages

      processes.each do |process, process_instances|
        unless process.correct_quantity?(process_instances.size)
          messages << SupervisorMessages.new(
            type: "incorrect_quantity",
            process: process.name,
            current: process_instances.size,
            desired: process.quantity,
          )
        end
        process_instances.each do |instance|
          if instance.should_be_running? && instance.status != "Running"
            messages << SupervisorMessages.new(
              type: "not_running",
              instance: instance.description,
              status: instance.status,
            )
          end
        end
      end

      messages
    end

    def add_reader(instance, io)
      @readers[io] = instance
      @signal_handler.notice
    end

    def add_instance(instance, io = nil)
      add_reader(instance, io) if io
      @processes[instance.process] ||= [] of Procodile::Instance
      unless @processes[instance.process].includes?(instance)
        @processes[instance.process] << instance
      end
    end

    def remove_instance(instance)
      if @processes[instance.process]
        @processes[instance.process].delete(instance)
        @readers.delete(instance)
      end
    end

    private def watch_for_output
      sleep_chan = Channel(Nil).new
      signal_handler_chan = Channel(Nil).new
      listener_chan = Channel(Nil).new

      spawn do
        loop do
          sleep 30
          @signal_handler.handle
          sleep_chan.send nil
        end
      end

      spawn do
        loop do
          @signal_handler.handle
          @signal_handler.pipe[:reader].read(Bytes.new(999)) rescue nil
          signal_handler_chan.send nil
        end
      end

      @readers.keys.each do |reader|
        spawn do
          buffer = {} of IO::FileDescriptor => String

          loop do
            @signal_handler.handle

            if reader.read_byte
              reader.close
              buffer.delete(reader)
              @readers.delete(reader)
            else
              buffer[reader] ||= ""
              buffer[reader] += reader.read_string(4096)

              while buffer[reader].index("\n")
                line, buffer[reader] = buffer[reader].split("\n", 2)
                if instance = @readers[reader]
                  Procodile.log instance.process.log_color, instance.description, "=> ".color(instance.process.log_color) + line
                else
                  Procodile.log nil, "unknown", buffer[reader]
                end
              end
            end

            listener_chan.send nil
          end
        end
      end

      spawn do
        loop do
          select
          when sleep_chan.receive
          when signal_handler_chan.receive
          when listener_chan.receive
          end
        end
      end
    end

    private def check_instance_quantities(type = :both, processes = nil) : Hash(Symbol, Array(Procodile::Instance))
      status = {:started => [] of Procodile::Instance, :stopped => [] of Procodile::Instance}

      @processes.each do |process, instances|
        next if processes && !processes.includes?(process.name)

        if (type == :both || type == :stopped) && (instances.size > process.quantity)
          quantity_to_stop = instances.size - process.quantity
          Procodile.log nil, "system", "Stopping #{quantity_to_stop} #{process.name} process(es)"
          stopped_instances = instances.first(quantity_to_stop)
          stopped_instances.each(&.stop)
          status[:stopped] = stopped_instances
        end

        if (type == :both || type == :started) && (instances.size < process.quantity)
          quantity_needed = process.quantity - instances.size
          Procodile.log nil, "system", "Starting #{quantity_needed} more #{process.name} process(es)"
          started_instances = process.generate_instances(self, quantity_needed)
          started_instances.each(&.start)
          status[:started] = started_instances
        end
      end

      status
    end

    private def remove_stopped_instances
      @processes.each do |_, instances|
        instances.reject! do |instance|
          if instance.stopping? && !instance.running?
            instance.on_stop
            true
          else
            false
          end
        end
      end
    end

    private def remove_removed_processes
      @processes.reject! do |process, instances|
        if process.removed && instances.empty?
          @tcp_proxy.try &.remove_process(process)
          true
        else
          false
        end
      end
    end

    private def process_names_to_instances(names)
      names.each_with_object([] of Procodile::Instance) do |name, array|
        if name =~ /\A(.*)\.(\d+)\z/
          process_name, id = $1, $2
          @processes.each do |process, instances|
            next unless process.name == process_name

            instances.each do |instance|
              next unless instance.id == id.to_i

              array << instance
            end
          end
        else
          @processes.each do |process, instances|
            next unless process.name == name

            instances.each { |i| array << i }
          end
        end
      end
    end
  end
end
