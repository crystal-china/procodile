module Procodile
  class ScheduleManager
    def initialize(@supervisor : Supervisor)
    end

    protected def scheduled_delay_seconds(process : Process) : Int32
      random_delay = process.random_delay
      return 0 if random_delay <= 0

      Random.rand(random_delay + 1)
    end
  end

  class Supervisor
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
        resolve_issue(:scheduled_run_failed, name)
        clear_scheduled_skip_state(name)
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

        clear_scheduled_skip_state(name)
        suggested_restart_command = @config.suggested_command("restart -p #{name}")

        report_issue(
          :invalid_schedule,
          name,
          "Scheduled process '#{name}' has invalid cron schedule '#{schedule}': #{ex.message}. \
Use 5 or 6 space-separated fields: seconds(optional) minute hour day month weekday. \
In Procfile, write `#{name}__AT__*/10 * * * * *: your-command` (`__AT__` has two underscores on both sides), \
or set `processes.#{name}.at: \"*/10 * * * * *\"` in the options files. Fix it, then run `#{@config.suggested_command("reload")}` \
or `#{suggested_restart_command}`."
        )
        Procodile.log "system", "Invalid cron schedule '#{schedule}' for #{name}: #{ex.message}"
        return
      end
      previous_next_time = Time.local - 1.minute

      loop do
        break unless scheduled_job_active?(name, schedule, signal)

        now = Time.local
        next_time = parser.next(now)
        next_time = parser.next(next_time) if next_time <= now
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

        if (process = @config.processes[name]?) && (delay = schedule_manager.scheduled_delay_seconds(process)) > 0
          select
          when signal.receive
            next
          when timeout delay.seconds
          end
        end

        next unless scheduled_job_active?(name, schedule, signal)

        run_scheduled_process(name)
      end
    end

    private def run_scheduled_process(name : String) : Nil
      process = @config.processes[name]?
      return unless process && process.scheduled?

      if @scheduled_running.includes?(name)
        skip_count = @scheduled_skip_counts[name] = (@scheduled_skip_counts[name]? || 0) + 1

        if skip_count >= SCHEDULED_SKIP_ISSUE_THRESHOLD
          report_issue(
            :scheduled_run_skipped_repeatedly,
            name,
            "Scheduled process '#{name}' skipped #{skip_count} runs because the previous run is still active. Consider increasing the schedule interval or shortening the task runtime."
          )
        end

        Procodile.log "system", "Skipping scheduled run for #{name}; previous run is still active"
        return
      end

      clear_scheduled_skip_state(name)
      @scheduled_running.add(name)

      Procodile.log "system", "Running scheduled process #{name}"

      process.create_instance(self).start
    rescue ex
      @scheduled_running.delete(name)
      Procodile.log "system", "Scheduled process #{name} failed to start: #{ex.message}"
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
        last_exit_status = instance.process.last_exit_status || -1
        suggested_command = @config.suggested_command("restart -p #{process_name}")

        report_issue(
          :scheduled_run_failed,
          process_name,
          "Scheduled process '#{process_name}' failed with exit \
status #{last_exit_status}. Fix it, then run `#{suggested_command}`."
        )
      end
    end

    private def scheduled_processes_for(process_names : Array(String)?) : Array(Procodile::Process)
      selected = if process_names
                   process_names.compact_map do |name|
                     process_name = resolve_process_and_instance(name).first
                     @config.processes[process_name]?
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

    private def scheduled_job_active?(name : String, schedule : String, signal : Channel(Nil)) : Bool
      @scheduled_jobs[name]? == schedule && @scheduled_job_signals[name]? == signal
    end
  end
end
