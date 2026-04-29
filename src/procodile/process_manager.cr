module Procodile
  class ProcessManager
    delegate config, to: @supervisor

    def initialize(@supervisor : Supervisor, @issue_tracker : IssueTracker)
    end

    def stop_processes(process_names : Array(String)?) : Array(Instance)
      instances_stopped = [] of Instance

      if process_names.nil?
        Procodile.log "system", "Stopping all #{config.app_name} processes"

        @supervisor.processes.each do |_, instances|
          instances.each do |instance|
            instance.stop
            instances_stopped << instance
          end
        end
      else
        instances = long_running_instances(process_selectors: process_names)

        Procodile.log "system", "Stopping #{instances.size} process(es)"

        instances.each do |instance|
          instance.stop
          instances_stopped << instance
        end
      end

      instances_stopped
    end

    def remove_stopped_instances : Nil
      @supervisor.processes.each do |_, instances|
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

    def remove_removed_processes : Nil
      @supervisor.processes.reject! do |process, instances|
        if process.removed? && instances.empty?
          @issue_tracker.clear_process(process.name)

          if (tcp_proxy = @supervisor.tcp_proxy)
            tcp_proxy.remove_process(process)
          end

          true
        else
          false
        end
      end
    end

    def restart_processes(process_names : Array(String)?) : Array(Array(Instance | Nil))
      wg = WaitGroup.new
      instances_restarted = [] of Array(Instance?)

      if process_names.nil?
        instances = @supervisor.processes.each_with_object([] of Instance) do |(process, process_instances), array|
          next if process.removed?
          next if process.scheduled?

          array.concat(process_instances)
        end

        Procodile.log "system", "Restarting all #{config.app_name} processes"
      else
        instances = long_running_instances(process_selectors: process_names)

        Procodile.log "system", "Restarting #{instances.size} process(es)"
      end

      # Stop any processes that are no longer wanted at this point
      stopped = stop_excess_instances(process_names).map { |instance| [instance, nil] }
      instances_restarted.concat stopped

      instances.each do |instance|
        next if instance.stopping?

        new_instance = instance.restart(wg)
        instances_restarted << [instance, new_instance]
      end

      # Start any processes that are needed at this point
      checked = start_missing_instances(process_names).map { |instance| [nil, instance] }
      instances_restarted.concat checked

      # 确保所有的 @reader 设定完毕，再启动 log listener
      wg.wait

      instances_restarted
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

    def reconcile_instance_quantities(process_names : Array(String)? = nil) : Hash(Symbol, Array(Instance))
      stopped = stop_excess_instances(process_names)
      started = start_missing_instances(process_names)

      {
        :started => started,
        :stopped => stopped,
      }
    end

    def messages : Array(Message)
      messages = [] of Message

      @supervisor.processes.each do |process, process_instances|
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

    private def long_running_instances(*, process_selectors : Array(String))
      instances_for(process_selectors: process_selectors).reject do |instance|
        instance.process.scheduled? && process_selectors.includes?(instance.process.name)
      end
    end

    private def instances_for(*, process_selectors : Array(String)) : Array(Instance)
      process_selectors.each_with_object([] of Instance) do |name, array|
        process_name, instance_id = ProcessSelector.parse(name)

        # 如果进程不在 Procfile 中，用原始 name 在 @supervisor.processes 中查找（已被移除的进程）
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

    private def start_missing_instances(process_names : Array(String)? = nil) : Array(Instance)
      started = [] of Instance

      each_target_long_running_process(process_names) do |process, instances|
        next unless instances.size < process.quantity

        quantity_needed = process.quantity - instances.size
        started_instances = process.generate_instances(@supervisor, quantity_needed)

        Procodile.log "system", "Starting #{quantity_needed} more #{process.name} process(es)"

        # 现在如果进程第一次启动就炸了，会 rescue 并 report_issue, 而不像之前那样，
        # 直接异常向上抛出，并让 supervisor 一起炸掉。
        # 因此，这里需要额外限制，没有 pid 的进程（炸掉的进程）不要加入显示为 started.
        started_instances.each do |instance|
          instance.start
          started << instance if instance.pid
        end
      end

      started
    end

    private def stop_excess_instances(process_names : Array(String)? = nil) : Array(Instance)
      stopped = [] of Instance

      each_target_long_running_process(process_names) do |process, instances|
        next unless instances.size > process.quantity

        quantity_to_stop = instances.size - process.quantity
        stopped_instances = instances.first(quantity_to_stop)

        Procodile.log "system", "Stopping #{quantity_to_stop} #{process.name} process(es)"

        stopped_instances.each(&.stop)
        stopped.concat(stopped_instances)
      end

      stopped
    end

    private def each_target_long_running_process(process_names : Array(String)? = nil, & : Procodile::Process, Array(Instance) ->)
      config.processes.each do |_, process|
        next if process_names && !process_names.includes?(process.name)
        next if process.scheduled?

        instances = @supervisor.processes[process]? || [] of Instance
        yield process, instances
      end
    end

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
  end
end
