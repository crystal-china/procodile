module Procodile
  # class ScheduleManager
  class Supervisor
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

    protected def scheduled_delay_seconds(process : Process) : Int32
      random_delay = process.random_delay
      return 0 if random_delay <= 0

      Random.rand(random_delay + 1)
    end
  end
end
