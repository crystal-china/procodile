require "./logger"
require "./control_server"
require "./signal_handler"
require "./schedule_manager"

module Procodile
  class Supervisor
    PROCESS_INSTANCE_REGEX         = /\A(.+)\.(\d+)\z/

    @started_at : Time?
    @runtime_issues : Hash(String, Supervisor::RuntimeIssue) = {} of String => Supervisor::RuntimeIssue

    getter tag : String?
    getter tcp_proxy : TCPProxy?
    getter started_at : Time?
    getter config : Config
    getter run_options : Supervisor::RunOptions
    getter processes : Hash(Procodile::Process, Array(Instance)) = {} of Procodile::Process => Array(Instance)
    getter readers : Hash(IO::FileDescriptor, Instance) = {} of IO::FileDescriptor => Instance
    @schedule_manager : Procodile::ScheduleManager?
    @log_reader_workers : Hash(IO::FileDescriptor, Bool) = {} of IO::FileDescriptor => Bool

    def initialize(
      @config : Config,
      @run_options : Supervisor::RunOptions = Supervisor::RunOptions.new,
    )
      @signal_handler = SignalHandler.new
      @signal_handler_chan = Channel(Nil).new
      @log_listener_chan = Channel(Nil).new
      @schedule_manager = ScheduleManager.new(self)

      @signal_handler.register(Signal::TERM) { stop_supervisor }
      @signal_handler.register(Signal::INT) { stop(Supervisor::Options.new(stop_supervisor: true)) }
      @signal_handler.register(Signal::USR1) { restart }
      @signal_handler.register(Signal::USR2) { }
      @signal_handler.register(Signal::HUP) { reload_config }
    end

    def allow_respawning? : Bool
      @run_options.respawn? != false
    end

    def start(after_start : Proc(Supervisor, Nil)) : Nil
      Procodile.log "system", "Procodile supervisor started with PID #{::Process.pid}"
      Procodile.log "system", "Application root is #{@config.root}"

      if @run_options.respawn? == false
        Procodile.log "system", "Automatic respawning is disabled"
      end

      ControlServer.start(self)

      # 先监听
      watch_for_output

      if @run_options.proxy?
        Procodile.log "system", "Proxy is enabled"

        @tcp_proxy = TCPProxy.start(self)
      end

      # 再启动进程
      after_start.call(self) # invoke supervisor.start_processes

      @started_at = Time.local
    rescue e
      Procodile.log_exception("system", "Supervisor startup failed", e)
      stop(Supervisor::Options.new(stop_supervisor: true))
    ensure
      loop { supervise; sleep 3.seconds }
    end

    def start_processes(
      process_names : Array(String)?,
      options : Supervisor::Options = Supervisor::Options.new,
    ) : Array(Instance)
      @tag = options.tag
      instances_started = [] of Instance

      reload_config
      schedule_manager.start_processes(process_names)

      @config.processes.each do |name, process|
        next if process_names && !process_names.includes?(name.to_s) # Not a process we want
        next if process.scheduled?
        next if @processes[process]? && !@processes[process].empty? # Process type already running

        instances = process.generate_instances(self)
        instances.each do |instance|
          instance.start
          instances_started << instance if instance.pid
        end
      end

      instances_started
    end

    def stop(options : Supervisor::Options = Supervisor::Options.new) : Array(Instance)
      @run_options.stop_when_none = true if options.stop_supervisor

      reload_config

      processes = options.processes
      schedule_manager.stop_processes(processes)

      instances_stopped = [] of Instance

      if processes.nil?
        Procodile.log "system", "Stopping all #{@config.app_name} processes"

        @processes.each do |_, instances|
          instances.each do |instance|
            instance.stop
            instances_stopped << instance
          end
        end
      else
        instances = long_running_instances(processes)

        Procodile.log "system", "Stopping #{instances.size} process(es)"

        instances.each do |instance|
          instance.stop
          instances_stopped << instance
        end
      end

      instances_stopped
    end

    def run_use_foreground? : Bool
      @run_options.foreground?
    end

    def restart(
      options : Supervisor::Options = Supervisor::Options.new,
    ) : Array(Array(Instance | Nil))
      wg = WaitGroup.new
      @tag = options.tag
      instances_restarted = [] of Array(Instance?)
      processes = options.processes

      reload_config
      schedule_manager.start_processes(processes)

      if processes.nil?
        instances = @processes.each_with_object([] of Instance) do |(process, process_instances), array|
          next if process.removed?
          next if process.scheduled?

          array.concat(process_instances)
        end

        Procodile.log "system", "Restarting all #{@config.app_name} processes"
      else
        instances = long_running_instances(processes)

        Procodile.log "system", "Restarting #{instances.size} process(es)"
      end

      # Stop any processes that are no longer wanted at this point
      stopped = check_instance_quantities(:stopped, processes)[:stopped].map { |i| [i, nil] }
      instances_restarted.concat stopped

      instances.each do |instance|
        next if instance.stopping?

        new_instance = instance.restart(wg)
        instances_restarted << [instance, new_instance]
      end

      # Start any processes that are needed at this point
      checked = check_instance_quantities(:started, processes)[:started].map { |i| [nil, i] }
      instances_restarted.concat checked

      # 确保所有的 @reader 设定完毕，再启动 log listener
      # 这个代码仍旧有机会造成 UNIXSever 立即退出，但是没有任何 backtrace, 原因未知
      wg.wait

      instances_restarted
    end

    def stop_supervisor : Nil
      Procodile.log "system", "Stopping Procodile supervisor"

      @tcp_proxy.try &.stop

      FileUtils.rm_rf(File.join(@config.pid_root, "procodile.pid"))

      exit 0
    end

    def reload_config : Nil
      Procodile.log "system", "Reloading configuration"

      @config.reload
      @tcp_proxy.try &.sync_processes(@config.processes.values)
      schedule_manager.sync_scheduled_processes
    end

    def check_concurrency(
      options : Supervisor::Options = Supervisor::Options.new,
    ) : Hash(Symbol, Array(Instance))
      Procodile.log "system", "Checking process concurrency"

      reload_config unless options.reload == false

      result = check_instance_quantities

      if result[:started].empty? && result[:stopped].empty?
        Procodile.log "system", "Process concurrency looks good"
      else
        if result[:started].present?
          Procodile.log "system", "Concurrency check \
started #{result[:started].map(&.description).join(", ")}"
        end

        if result[:stopped].present?
          Procodile.log "system", "Concurrency check \
stopped #{result[:stopped].map(&.description).join(", ")}"
        end
      end

      result
    end

    def schedule_manager : ScheduleManager
      @schedule_manager.not_nil!
    end

    def to_hash : NamedTuple(started_at: Int64?, pid: Int64, proxy_enabled: Bool)
      started_at = @started_at

      {
        started_at:    started_at ? started_at.to_unix : nil,
        pid:           ::Process.pid,
        proxy_enabled: !!@run_options.proxy?,
      }
    end

    def messages : Array(Message)
      messages = [] of Message

      processes.each do |process, process_instances|
        next if process.scheduled?

        if process.removed? && process_instances.any?(&.status.running?)
          messages << Message.new(
            type: :removed_but_running,
            process: process.name,
          )
        end

        unless process.correct_quantity?(process_instances.size)
          messages << Message.new(
            type: :incorrect_quantity,
            process: process.name,
            current: process_instances.size,
            desired: process.quantity,
          )
        end

        process_instances.each do |instance|
          if instance.should_be_running? && !instance.status.running?
            messages << Message.new(
              type: :not_running,
              instance: instance.description,
              status: instance.status,
            )
          end
        end
      end

      messages
    end

    def runtime_issues : Array(RuntimeIssue)
      @runtime_issues.values.sort_by { |issue| {issue.process_name, issue.type.to_s} }
    end

    def report_issue(type : RuntimeIssueType, process_name : String, message : String) : Nil
      key = runtime_issue_key(type, process_name)
      @runtime_issues[key] = RuntimeIssue.new(
        key: key,
        type: type,
        process_name: process_name,
        message: message
      )
    end

    def resolve_issue(type : RuntimeIssueType, process_name : String) : Nil
      @runtime_issues.delete(runtime_issue_key(type, process_name))
    end

    private def runtime_issue_key(type : RuntimeIssueType, process_name : String) : String
      "#{type.to_s.underscore}:#{process_name}"
    end

    private def clear_runtime_issues_for_process(process_name : String) : Nil
      RuntimeIssueType.values.each do |type|
        resolve_issue(type, process_name)
      end
    end

    def add_instance(instance : Instance, io : IO::FileDescriptor? = nil) : Nil
      add_reader(instance, io) if io

      # When the first time start, it is possible @processes[instance.process] is nil
      # before the process is started.
      @processes[instance.process] ||= [] of Instance

      unless @processes[instance.process].includes?(instance)
        @processes[instance.process] << instance
      end
    end

    def remove_instance(instance : Instance) : Nil
      if @processes[instance.process]
        @processes[instance.process].delete(instance)

        # Only useful when run in foreground
        key = @readers.key_for?(instance)
        @readers.delete(key) if key
      end
    end

    private def supervise : Nil
      # Tell instances that have been stopped that they have been stopped
      remove_stopped_instances

      # Remove removed processes
      remove_removed_processes

      # Check all instances that we manage and let them do their things.
      @processes.each do |_, instances|
        instances.each(&.check)
      end

      # If the processes go away, we can stop the supervisor now
      if @run_options.stop_when_none? && all_instances_stopped?
        Procodile.log "system", "All processes have stopped"

        stop_supervisor
      end
    rescue ex
      Procodile.log_exception("system", "Supervisor loop failed", ex)
    end

    private def watch_for_output : Nil
      spawn watch_for_signal_events

      log_listener_reader

      spawn do
        loop do
          select
          when @signal_handler_chan.receive
          when @log_listener_chan.receive
          when timeout 30.seconds
          end
        end
      end
    end

    private def watch_for_signal_events : Nil
      loop do
        byte = @signal_handler.pipe[:reader].read_byte

        break if byte.nil?

        @signal_handler.handle(byte)

        @signal_handler_chan.send nil
      end
    end

    private def log_listener_reader : Nil
      # After run restart command, @readers need to be update.
      # Ruby version @readers is wrapped by a loop, so can workaround this.
      # Crystal version need rerun this method again after restart.

      # Restart may add readers, so this method can be called multiple times.
      # Ensure one worker per reader to avoid duplicate consumers/fiber leaks.
      @readers.keys.each do |reader|
        next if @log_reader_workers[reader]?

        @log_reader_workers[reader] = true
        spawn watch_log_reader(reader)
      end
    end

    private def watch_log_reader(reader : IO::FileDescriptor) : Nil
      # 改成 while 的原因:

      # 1. while (line = reader.gets)
      # - 当没有数据时会阻塞等待。
      # - 当 FD 关闭/EOF 时返回 nil，循环自然退出，进入 ensure 清理。
      # - 不会出现“永远 sleep 0.1 秒轮询”的空转。
      # 2. 移除 Fiber.yield
      # - gets 阻塞时，调度器会自动切换其他 fiber，所以不需要手动 yield。
      # 3. 移除 sleep 0.1
      # - 这是旧版为了避免忙等的“轮询退让”。
      # - 现在用阻塞读，没有忙等，也就不需要 sleep。
      while (line = reader.gets(chomp: true))
        if (instance = @readers[reader]?)
          Procodile.log(
            instance.description,
            "#{"=>".colorize(instance.process.log_color)} #{line}",
            instance.process.log_color
          )
        else
          Procodile.log "unknown", line
        end

        @log_listener_chan.send nil
      end
    rescue ex : IO::Error
      Procodile.log "system", "Log reader closed: #{ex.message}"
    ensure
      @readers.delete(reader)
      @log_reader_workers.delete(reader)
      reader.close rescue nil
    end

    private def check_instance_quantities(
      type : Supervisor::CheckInstanceQuantitiesType = :both,
      processes : Array(String)? = nil,
    ) : Hash(Symbol, Array(Instance))
      status = {:started => [] of Instance, :stopped => [] of Instance}

      @config.processes.each do |_, process|
        next if processes && !processes.includes?(process.name)
        next if process.scheduled?

        instances = @processes[process]? || [] of Instance

        if (type.both? || type.stopped?) && instances.size > process.quantity
          quantity_to_stop = instances.size - process.quantity
          stopped_instances = instances.first(quantity_to_stop)

          Procodile.log "system", "Stopping #{quantity_to_stop} #{process.name} process(es)"

          stopped_instances.each(&.stop)
          status[:stopped].concat(stopped_instances)
        end

        if (type.both? || type.started?) && instances.size < process.quantity
          quantity_needed = process.quantity - instances.size
          started_instances = process.generate_instances(self, quantity_needed)

          Procodile.log "system", "Starting #{quantity_needed} more #{process.name} process(es)"

          # 现在如果进程第一次启动就炸了，会 rescue 并 report_issue, 而不像之前那样，
          # 直接异常向上抛出，并让 supervisor 一起炸掉。
          # 因此，这里需要额外限制，没有 pid 的进程（炸掉的进程）不要加入显示为 started.
          started_instances.each do |instance|
            instance.start
            status[:started] << instance if instance.pid
          end
        end
      end

      status
    end

    private def remove_stopped_instances : Nil
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

    private def remove_removed_processes : Nil
      @processes.reject! do |process, instances|
        if process.removed? && instances.empty?
          clear_runtime_issues_for_process(process.name)

          if (tcp_proxy = @tcp_proxy)
            tcp_proxy.remove_process(process)
          end

          true
        else
          false
        end
      end
    end

    private def process_names_to_instances(names : Array(String)) : Array(Instance)
      names.each_with_object([] of Instance) do |name, array|
        process_name, instance_id = resolve_process_and_instance(name)

        # 如果进程不在 Procfile 中，用原始 name 在 @processes 中查找（已被移除的进程）
        target_name = process_name || name

        @processes.each do |process, instances|
          next unless process.name == target_name

          if instance_id
            instances.each { |instance| array << instance if instance.id == instance_id }
          else
            instances.each { |instance| array << instance }
          end
        end
      end
    end

    # 解析用户输入的名称，返回 (进程名, instance_id) 元组
    # - instance_id 为 nil 表示匹配所有实例
    protected def resolve_process_and_instance(name : String) : Tuple(String, Int32?)
      if (match = name.match(PROCESS_INSTANCE_REGEX))
        {match[1], match[2].to_i32}
      else
        {name, nil}
      end
    end

    private def all_instances_stopped? : Bool
      @processes.all? do |_, instances|
        instances.reject(&.failed?).empty?
      end
    end

    private def add_reader(instance : Instance, io : IO::FileDescriptor) : Nil
      @readers[io] = instance

      @signal_handler.wakeup

      log_listener_reader
    end

    private def long_running_instances(processes : Array(String))
      process_names_to_instances(processes).reject do |instance|
        instance.process.scheduled? && processes.includes?(instance.process.name)
      end
    end

    # Supervisor message
    struct Message
      # Message type
      enum Type
        NotRunning
        IncorrectQuantity
        RemovedButRunning
      end

      include JSON::Serializable

      getter type : Type
      getter process : String?
      getter current : Int32?
      getter desired : Int32?
      getter instance : String?
      getter status : Instance::Status?

      def initialize(
        @type : Type,
        @process : String? = nil,
        @current : Int32? = nil,
        @desired : Int32? = nil,
        @instance : String? = nil,
        @status : Instance::Status? = nil,
      )
      end

      def to_s(io : IO) : Nil
        case type
        in .not_running?
          io.print "#{instance} is not running (#{status})"
        in .incorrect_quantity?
          io.print "#{process} has #{current} instances (should have #{desired})"
        in .removed_but_running?
          io.print "#{process} has been removed from the Procfile but is still running; \
run `procodile stop -p #{process}` to stop it"
        end
      end
    end

    enum RuntimeIssueType
      ProcessFailedPermanently
      ScheduledRunFailed
      InvalidSchedule
      ScheduledRunSkippedRepeatedly
    end

    struct RuntimeIssue
      include JSON::Serializable

      getter key : String
      getter type : RuntimeIssueType
      getter process_name : String
      getter message : String

      def initialize(
        @key : String,
        @type : RuntimeIssueType,
        @process_name : String,
        @message : String,
      )
      end
    end
  end

  enum Supervisor::CheckInstanceQuantitiesType
    Both
    Started
    Stopped
  end

  struct Supervisor::RunOptions
    property port_allocations : Hash(String, Int32)?
    property env_file : String?

    property? proxy : Bool?
    property? force_single_log : Bool?
    property? respawn : Bool?
    property? stop_when_none : Bool?

    property? foreground : Bool

    def initialize(
      @port_allocations : Hash(String, Int32)? = nil,
      @env_file : String? = nil,
      @proxy : Bool? = nil,
      @force_single_log : Bool? = nil,
      @respawn : Bool? = nil,
      @stop_when_none : Bool? = nil,
      @foreground : Bool = false,
    )
    end
  end

  # 这种写法允许以任意方式初始化 Supervisor::Options
  struct Supervisor::Options
    getter processes : Array(String)?
    getter stop_supervisor : Bool?
    getter tag : String?
    getter reload : Bool?

    def initialize(
      @processes : Array(String)? = nil,
      @stop_supervisor : Bool? = nil,
      @tag : String? = nil,
      @reload : Bool? = nil,
    )
    end
  end
end
