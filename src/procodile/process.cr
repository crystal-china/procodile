require "./instance"

module Procodile
  class Process
    @@mutex = Mutex.new

    @log_color : Colorize::ColorANSI = Colorize::ColorANSI::Default
    @instance_index : Int32 = 0
    @removed : Bool = false

    getter config, name
    property command, options, log_color, removed

    delegate allocate_port_from, proxy_port, to: @options

    def initialize(
      @config : Procodile::Config,
      @name : String,
      @command : String,
      @options : Option = Option.new
    )
    end

    #
    # Return all environment variables for this process
    #
    def environment_variables : Hash(String, String)
      global_variables = @config.environment_variables

      process_vars = if (process = @config.process_options[@name]?)
                       process.env || {} of String => String
                     else
                       {} of String => String
                     end

      process_local_vars = if (local_process = @config.local_process_options[@name]?)
                             local_process.env || {} of String => String
                           else
                             {} of String => String
                           end

      global_variables.merge(process_vars.merge(process_local_vars))
    end

    #
    # How many instances of this process should be started
    #
    def quantity : Int32
      @options.quantity || 1
    end

    #
    # The maximum number of times this process can be respawned in the given period
    #
    def max_respawns : Int32
      @options.max_respawns || 5
    end

    #
    # The respawn window. One hour by default.
    #
    def respawn_window : Int32
      @options.respawn_window || 3600
    end

    #
    # Return the path where log output for this process should be written to. If
    # none, output will be written to the supervisor log.
    #
    def log_path : String
      log_path = @options.log_path

      log_path ? File.expand_path(log_path, @config.root) : default_log_path
    end

    #
    # Return the log path for this process if no log path is provided and split logs
    # is enabled
    #
    def default_log_path : String
      if (lr = @config.log_root)
        File.join(lr, default_log_file_name)
      else
        File.join(@config.root, default_log_file_name)
      end
    end

    #
    # Return the defualt log file name
    #
    def default_log_file_name : String
      @options.log_file_name || "#{@name}.log"
    end

    #
    # Return the signal to send to terminate the process
    #
    def term_signal : Signal
      @options.term_signal || Signal::TERM
    end

    #
    # Defines how this process should be restarted
    #
    # start-term = start new instances and send term to children
    # usr1 = just send a usr1 signal to the current instance
    # usr2 = just send a usr2 signal to the current instance
    # term-start = stop the old instances, when no longer running, start a new one
    #
    def restart_mode : Signal | String
      @options.restart_mode || "term-start"
    end

    #
    # Return the network protocol for this process
    #
    def network_protocol : String
      @options.network_protocol || "tcp"
    end

    #
    # Is this process enabled for proxying?
    #
    def proxy? : Bool
      !!@options.proxy_port
    end

    #
    # Return the port for the proxy to listen on for this process type
    #
    def proxy_address : String?
      proxy? ? @options.proxy_address || "127.0.0.1" : nil
    end

    #
    # Generate an array of new instances for this process (based on its quantity)
    #
    def generate_instances(supervisor : Procodile::Supervisor, quantity : Int32 = self.quantity) : Array(Procodile::Instance)
      Array.new(quantity) { create_instance(supervisor) }
    end

    #
    # Create a new instance
    #
    def create_instance(supervisor : Procodile::Supervisor) : Instance
      # supervisor is A Procodile::Supervisor object like this:
      # {
      #   :started_at => 1667297292,
      #   :pid        => 410794,
      # }

      Instance.new(supervisor, self, instance_id)
    end

    #
    # Return a struct
    #
    def to_struct : ControlClient::ProcessStatus
      ControlClient::ProcessStatus.new(
        name: self.name,
        log_color: self.log_color,
        quantity: self.quantity,
        max_respawns: self.max_respawns,
        respawn_window: self.respawn_window,
        command: self.command,
        restart_mode: self.restart_mode,
        log_path: self.log_path,
        removed: self.removed ? true : false,
        proxy_port: proxy_port,
        proxy_address: proxy_address,
      )
    end

    #
    # Is the given quantity suitable for this process?
    #
    def correct_quantity?(quantity : Int32) : Bool
      if self.restart_mode == "start-term"
        quantity >= self.quantity
      else
        self.quantity == quantity
      end
    end

    #
    # Increase the instance index and return
    #
    private def instance_id : Int32
      @@mutex.synchronize do
        @instance_index = 0 if @instance_index == 10000
        @instance_index += 1
      end
    end

    struct Option
      include YAML::Serializable

      # How many instances of this process should be started
      property quantity : Int32?

      # Defines how this process should be restarted
      #
      # start-term = start new instances and send term to children
      # Signal::USR1 = just send a usr1 signal to the current instance
      # Signal::USR2 = just send a usr2 signal to the current instance
      # term-start = stop the old instances, when no longer running, start a new one
      property restart_mode : Signal | String | Nil

      # The maximum number of times this process can be respawned in the given period
      property max_respawns : Int32?

      # The respawn window. One hour by default.
      property respawn_window : Int32?
      property log_path : String?
      property log_file_name : String?

      # Return the signal to send to terminate the process
      property term_signal : Signal?

      # Return the first port that ports should be allocated from for this process
      property allocate_port_from : Int32?

      # Return the port for the proxy to listen on for this process type
      property proxy_port : Int32?

      # property proxy_address : String?
      property proxy_address : String?

      # Return the network protocol for this process
      property network_protocol : String?

      property env = {} of String => String

      def initialize
      end

      def merge(other : self?) : self
        new_process_option = self

        {% for i in @type.instance_vars %}
          {% if i.name != "env" %}
            new_process_option.{{i.name}} = other.{{i.name}} if other.{{i.name}}
          {% end %}
        {% end %}

        new_process_option.env = new_process_option.env.merge(other.env) if other.env

        new_process_option
      end
    end
  end
end
