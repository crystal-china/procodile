module Procodile
  module AppResolution
    def self.resolve(options) : AppDetermination
      determine_app(FileUtils.pwd, options, load_global_config)
    end

    private def self.load_global_config : Array(Config::GlobalOption)
      global_config_path = ENV["PROCODILE_CONFIG"]? || "/etc/procodile"

      if File.file?(global_config_path)
        global_config_yaml = File.read(global_config_path)
        global_config_node = YAML.parse(global_config_yaml)

        if global_config_node.raw.is_a?(Array)
          Array(Config::GlobalOption).from_yaml(global_config_yaml)
        elsif global_config_node.raw.is_a?(Hash)
          [Config::GlobalOption.from_yaml(global_config_yaml)]
        else
          raise Error.new("Invalid global configuration format in #{global_config_path}")
        end
      else
        [] of Config::GlobalOption
      end
    end

    private def self.determine_app(pwd : String, options : Hash(Symbol, String), global_config : Array(Config::GlobalOption)) : AppDetermination
      # Create a determination to work out where we want to load our app from
      ap = AppDetermination.new(
        pwd,
        options[:root]?,
               options[:procfile]?,
               global_config
      )

      if ap.ambiguous?
        if (app_id = ENV["PROCODILE_APP_ID"]?)
          ap.set_app_id_and_find_root_and_procfile(app_id.to_i)
        elsif ap.app_options.empty?
          abort "Error: Could not find Procfile in #{pwd}/Procfile".colorize.red
        else
          choose_application(ap)
        end
      end

      ap
    end

    private def self.choose_application(ap : AppDetermination) : Nil
      puts "There are multiple applications configured in #{ENV["PROCODILE_CONFIG"]? || "/etc/procodile"}"
      puts "Choose an application:".colorize.light_gray.on_magenta

      ap.app_options.each do |i, app|
        col = i % 3
        print "#{(i + 1)}) #{app}"[0, 28].ljust(col != 2 ? 30 : 0, ' ')
        if col == 2 || i == ap.app_options.size - 1
          puts
        end
      end

      input = STDIN.gets

      return if input.nil?

      app_id = input.strip.to_i - 1

      if ap.app_options[app_id]?
        ap.set_app_id_and_find_root_and_procfile(app_id)
      else
        abort "Invalid app number: #{app_id + 1}"
      end
    end
  end
end
