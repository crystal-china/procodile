require "./logger"
require "./control_server"
require "./signal_handler"
require "./process_selector"
require "./process_manager"
require "./schedule_manager"

module Procodile
  class Supervisor
    @process_manager : Procodile::ProcessManager?
    @schedule_manager : Procodile::ScheduleManager?

    @started_at : Time?
    @runtime_issues : Hash(String, Supervisor::RuntimeIssue) = {} of String => Supervisor::RuntimeIssue
    @log_reader_workers : Hash(IO::FileDescriptor, Bool) = {} of IO::FileDescriptor => Bool

    getter tag : String?
    getter tcp_proxy : TCPProxy?
    getter started_at : Time?
    getter config : Config
    getter run_options : Supervisor::RunOptions
    getter processes : Hash(Procodile::Process, Array(Instance)) = {} of Procodile::Process => Array(Instance)
    getter readers : Hash(IO::FileDescriptor, Instance) = {} of IO::FileDescriptor => Instance

    def initialize(
      @config : Config,
      @run_options : Supervisor::RunOptions = Supervisor::RunOptions.new,
    )
      @signal_handler = SignalHandler.new
      @signal_handler_chan = Channel(Nil).new
      @log_listener_chan = Channel(Nil).new

      @process_manager = ProcessManager.new(self)
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
      # ---------------- boot services ----------------

      Procodile.log "system", "Procodile supervisor started with PID #{::Process.pid}"
      Procodile.log "system", "Application root is #{@config.root}"

      if @run_options.respawn? == false
        Procodile.log "system", "Automatic respawning is disabled"
      end

      ControlServer.start(self)

      # 先监听
      watch_for_output

      # ---------------- boot proxy ----------------

      if @run_options.proxy?
        Procodile.log "system", "Proxy is enabled"

        @tcp_proxy = TCPProxy.start(self)
      end

      # ---------------- boot processes ----------------
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
      reload_config
      schedule_manager.enable_schedules(process_names)
      process_manager.start_processes(process_names)
    end

    def stop(options : Supervisor::Options = Supervisor::Options.new) : Array(Instance)
      @run_options.stop_when_none = true if options.stop_supervisor

      reload_config

      process_names = options.process_names

      schedule_manager.disable_schedules(process_names)
      process_manager.stop_processes(process_names)
    end

    def run_use_foreground? : Bool
      @run_options.foreground?
    end

    def restart(
      options : Supervisor::Options = Supervisor::Options.new,
    ) : Array(Array(Instance | Nil))
      @tag = options.tag
      process_names = options.process_names

      reload_config
      schedule_manager.enable_schedules(process_names)
      process_manager.restart_processes(process_names)
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
      schedule_manager.reload_schedules
    end

    def check_concurrency(
      options : Supervisor::Options = Supervisor::Options.new,
    ) : Hash(Symbol, Array(Instance))
      Procodile.log "system", "Checking process concurrency"

      reload_config unless options.reload == false

      result = process_manager.reconcile_instance_quantities

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

    protected def process_manager : ProcessManager
      @process_manager.not_nil!
    end

    protected def schedule_manager : ScheduleManager
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

    def clear_runtime_issues_for_process(process_name : String) : Nil
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
      process_manager.remove_stopped_instances

      # Remove removed processes
      process_manager.remove_removed_processes

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
    getter process_names : Array(String)?
    getter stop_supervisor : Bool?
    getter tag : String?
    getter reload : Bool?

    def initialize(
      @process_names : Array(String)? = nil,
      @stop_supervisor : Bool? = nil,
      @tag : String? = nil,
      @reload : Bool? = nil,
    )
    end
  end
end
