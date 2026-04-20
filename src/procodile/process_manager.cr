module Procodile
  class ProcessManager
    delegate config, to: @supervisor

    def initialize(@supervisor : Supervisor)
    end

    def start_processes(process_names : Array(String)?) : Array(Instance)
      instances_started = [] of Instance

      config.processes.each do |name, process|
        next if process_names && !process_names.includes?(name.to_s) # Not a process we want
        next if process.scheduled?
        next if @supervisor.processes[process]? && !@supervisor.processes[process].empty? # Process type already running

        instances = process.generate_instances(@supervisor)
        instances.each do |instance|
          instance.start
          instances_started << instance if instance.pid
        end
      end

      instances_started
    end

    def long_running_instances(processes : Array(String))
      process_names_to_instances(processes).reject do |instance|
        instance.process.scheduled? && processes.includes?(instance.process.name)
      end
    end

    def process_names_to_instances(names : Array(String)) : Array(Instance)
      names.each_with_object([] of Instance) do |name, array|
        process_name, instance_id = @supervisor.resolve_process_and_instance(name)

        # 如果进程不在 Procfile 中，用原始 name 在 @processes 中查找（已被移除的进程）
        target_name = process_name || name

        @supervisor.processes.each do |process, instances|
          next unless process.name == target_name

          if instance_id
            instances.each { |instance| array << instance if instance.id == instance_id }
          else
            instances.each { |instance| array << instance }
          end
        end
      end
    end

    def check_instance_quantities(
                 type : Supervisor::CheckInstanceQuantitiesType = :both,
                 processes : Array(String)? = nil,
               ) : Hash(Symbol, Array(Instance))
      status = {:started => [] of Instance, :stopped => [] of Instance}

      config.processes.each do |_, process|
        next if processes && !processes.includes?(process.name)
        next if process.scheduled?

        instances = @supervisor.processes[process]? || [] of Instance

        if (type.both? || type.stopped?) && instances.size > process.quantity
          quantity_to_stop = instances.size - process.quantity
          stopped_instances = instances.first(quantity_to_stop)

          Procodile.log "system", "Stopping #{quantity_to_stop} #{process.name} process(es)"

          stopped_instances.each(&.stop)
          status[:stopped].concat(stopped_instances)
        end

        if (type.both? || type.started?) && instances.size < process.quantity
          quantity_needed = process.quantity - instances.size
          started_instances = process.generate_instances(@supervisor, quantity_needed)

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
  end
end
