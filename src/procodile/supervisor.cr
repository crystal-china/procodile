require "./logger"
require "./control_server"
require "./signal_handler"

module Procodile
  class Supervisor
    @started_at : Time?
    # 要执行的任务，key 是 name, value 是 crontab
    @scheduled_jobs : Hash(String, String) = {} of String => String
    # 检测是不是当前正在运行
    @scheduled_running : Set(String) = Set(String).new
    # 加入这个 Set 的 process 不再调度
    @disabled_scheduled_jobs : Set(String) = Set(String).new
    # 用于唤醒旧 watcher 立即退出，避免软退出
    @scheduled_job_signals : Hash(String, Channel(Nil)) = {} of String => Channel(Nil)
    @runtime_issues : Hash(String, Supervisor::RuntimeIssue) = {} of String => Supervisor::RuntimeIssue

    getter tag : String?
    getter tcp_proxy : TCPProxy?
    getter started_at : Time?
    getter config : Config
    getter run_options : Supervisor::RunOptions
    getter processes : Hash(Procodile::Process, Array(Instance)) = {} of Procodile::Process => Array(Instance)
    getter readers : Hash(IO::FileDescriptor, Instance) = {} of IO::FileDescriptor => Instance
    @log_reader_workers : Hash(IO::FileDescriptor, Bool) = {} of IO::FileDescriptor => Bool

    def initialize(
      @config : Config,
      @run_options : Supervisor::RunOptions = Supervisor::RunOptions.new,
    )
      @signal_handler = SignalHandler.new
      @signal_handler_chan = Channel(Nil).new
      @log_listener_chan = Channel(Nil).new

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
      Procodile.log "system", "Error: #{e.class} (#{e.message})"

      e.backtrace.each { |bt| Procodile.log "system", "=> #{bt})" }

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
      enable_scheduled_processes(scheduled_processes_for(process_names))
      sync_scheduled_processes

      @config.processes.each do |name, process|
        next if process_names && !process_names.includes?(name.to_s) # Not a process we want
        next if process.scheduled?
        next if @processes[process]? && !@processes[process].empty? # Process type already running

        instances = process.generate_instances(self)
        instances.each &.start
        instances_started.concat instances
      end

      instances_started
    end

    def stop(options : Supervisor::Options = Supervisor::Options.new) : Array(Instance)
      @run_options.stop_when_none = true if options.stop_supervisor

      reload_config

      processes = options.processes
      disable_scheduled_processes(scheduled_processes_for(processes))
      sync_scheduled_processes
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
        instances = process_names_to_instances(processes)

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
      enable_scheduled_processes(scheduled_processes_for(processes))
      sync_scheduled_processes

      if processes.nil?
        instances = @processes.values.flatten

        Procodile.log "system", "Restarting all #{@config.app_name} processes"
      else
        instances = process_names_to_instances(processes)

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
      sync_scheduled_processes
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

    def to_hash : NamedTuple(started_at: Int64?, pid: Int64)
      started_at = @started_at

      {
        started_at: started_at ? started_at.to_unix : nil,
        pid:        ::Process.pid,
      }
    end

    def messages : Array(Message)
      messages = [] of Message

      processes.each do |process, process_instances|
        next if process.scheduled?

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
      @runtime_issues.values
    end

    def report_issue(type : RuntimeIssueType, process : String, message : String) : Nil
      key = runtime_issue_key(type, process)
      @runtime_issues[key] = RuntimeIssue.new(
        key: key,
        type: type,
        process: process,
        message: message
      )
    end

    def resolve_issue(type : RuntimeIssueType, process : String) : Nil
      @runtime_issues.delete(runtime_issue_key(type, process))
    end

    private def runtime_issue_key(type : RuntimeIssueType, process : String) : String
      "#{type.to_s.underscore}:#{process}"
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

    def finish_scheduled_instance(instance : Instance) : Nil
      stopped_by_user = instance.stopping?
      process_name = instance.process.name

      instance.on_scheduled_finish
      remove_instance(instance)
      scheduled_process_finished(instance)

      if stopped_by_user || instance.process.last_exit_status == 0
        resolve_issue(:scheduled_run_failed, process_name)
      else
        report_issue(
          :scheduled_run_failed,
          process_name,
          "Scheduled process '#{process_name}' failed with exit status \
#{instance.process.last_exit_status || -1}. Fix it, then run `procodile restart -p #{process_name}`."
        )
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
    end

    private def sync_scheduled_processes : Nil
      wanted = @config.processes.each_with_object({} of String => String) do |(name, process), hash|
        next unless process.scheduled?
        next if @disabled_scheduled_jobs.includes?(name)

        hash[name] = process.schedule.not_nil!
      end

      # keys 先返回一个独立的 Array(String)，后面 each 遍历的是这个数组，不是原 hash。
      # 因此，这里遍历时删除哈希元素是安全的。
      @scheduled_jobs.keys.each do |name|
        next if wanted.has_key?(name)

        signal_scheduled_job(name)
        @scheduled_jobs.delete(name)
        @scheduled_job_signals.delete(name)
        resolve_issue(:invalid_schedule, name)
      end

      wanted.each do |name, schedule|
        next if @scheduled_jobs[name]? == schedule && @scheduled_job_signals[name]?

        signal_scheduled_job(name)
        @scheduled_jobs[name] = schedule
        # 这里的 signal 不是“精确计数消息”，因此不是 new，而是使用 new(1)
        # 1 表示，不管 watcher 是啥状态（哪怕还没有阻塞在 receive），我也能把信号先放进去。
        # 然后下一次 select 的时候马上会收到。
        # 即：至少可以存进去一个待消费的退出信号，同时又不会无限堆积重复 signal（见 signal_scheduled_job 用法)
        # 如果这里用 0 的话，如果 watcher 还在计算 next_time 的时候（即还没到 #watch_scheduled_process
        # select receive 那一步），signal_scheduled_job 发送信号，因为 block 而会被丢弃，
        # watcher 因为没收到信号，会继续睡下去。
        signal = Channel(Nil).new(1)
        @scheduled_job_signals[name] = signal
        spawn watch_scheduled_process(name, schedule, signal)
      end
    end

    private def watch_scheduled_process(name : String, schedule : String, signal : Channel(Nil)) : Nil
      begin
        parser = CronParser.new(schedule)
        resolve_issue(:invalid_schedule, name)
      rescue ex
        if @scheduled_job_signals[name]? == signal
          @scheduled_jobs.delete(name)
          @scheduled_job_signals.delete(name)
        end

        report_issue(
          :invalid_schedule,
          name,
          "Scheduled process '#{name}' has invalid cron schedule '#{schedule}': #{ex.message}. Fix it, then run `procodile restart -p #{name}`."
        )
        Procodile.log "system", "Invalid cron schedule '#{schedule}' for #{name}: #{ex.message}"
        return
      end
      previous_next_time = Time.local - 1.minute

      loop do
        break unless scheduled_job_active?(name, schedule, signal)

        now = Time.local
        next_time = parser.next(now)
        next_time = parser.next(next_time) if next_time == previous_next_time
        previous_next_time = next_time

        sleep_time = next_time - now
        sleep_time = 0.seconds if sleep_time.negative? # 这个和前面的 if 都是防御性代码。

        select
        when signal.receive
          break
        when timeout sleep_time
        end

        next unless scheduled_job_active?(name, schedule, signal)

        run_scheduled_process(name)
      end
    end

    private def run_scheduled_process(name : String) : Nil
      process = @config.processes[name]?
      return unless process && process.scheduled?

      if @scheduled_running.includes?(name)
        Procodile.log "system", "Skipping scheduled run for #{name}; previous run is still active"
        return
      end

      @scheduled_running.add(name)

      Procodile.log "system", "Running scheduled process #{name}"

      process.create_instance(self).start
    rescue ex
      @scheduled_running.delete(name)
      report_issue(
        :scheduled_run_failed,
        name,
        "Scheduled process '#{name}' failed to start: #{ex.message}. Fix it, then run `procodile restart -p #{name}`."
      )
      Procodile.log "system", "Scheduled process #{name} failed to start: #{ex.message}"
    end

    private def scheduled_job_active?(name : String, schedule : String, signal : Channel(Nil)) : Bool
      @scheduled_jobs[name]? == schedule && @scheduled_job_signals[name]? == signal
    end

    private def scheduled_process_finished(instance : Instance) : Nil
      @scheduled_running.delete(instance.process.name)
    end

    private def scheduled_processes_for(process_names : Array(String)?) : Array(Procodile::Process)
      selected = if process_names
                   process_names.map do |name|
                     process_name = name.split('.', 2).first
                     @config.processes[process_name]
                   end
                 else
                   @config.processes.values
                 end

      selected.select(&.scheduled?)
    end

    private def enable_scheduled_processes(processes : Array(Procodile::Process)) : Nil
      processes.each do |process|
        @disabled_scheduled_jobs.delete(process.name)
      end
    end

    private def disable_scheduled_processes(processes : Array(Procodile::Process)) : Nil
      processes.each do |process|
        @disabled_scheduled_jobs.add(process.name)
      end
    end

    private def signal_scheduled_job(name : String) : Nil
      return unless (signal = @scheduled_job_signals[name]?)

      # 非阻塞 send，避免重复 signal 卡住
      select
      when signal.send(nil)
      else
      end
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

          started_instances.each(&.start)

          status[:started].concat(started_instances)
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
        if name =~ /\A(.*)\.(\d+)\z/ # app1.1
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

            instances.each { |instance| array << instance }
          end
        end
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

    # Supervisor message
    struct Message
      # Message type
      enum Type
        NotRunning
        IncorrectQuantity
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
        end
      end
    end

    enum RuntimeIssueType
      ProcessFailedPermanently
      ScheduledRunFailed
      InvalidSchedule
    end

    struct RuntimeIssue
      include JSON::Serializable

      getter key : String
      getter type : RuntimeIssueType
      getter process : String
      getter message : String

      def initialize(
        @key : String,
        @type : RuntimeIssueType,
        @process : String,
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
