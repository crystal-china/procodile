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
  end
end
