module Procodile
  private class_getter logger_mutex : Mutex { Mutex.new }

  def self.log(color : Colorize::ColorANSI?, name : String, text : String) : Nil
    color = Colorize::ColorANSI::Default if color.nil?

    logger_mutex.synchronize do
      text.each_line do |message|
        STDOUT << "#{Time.local.to_s("%H:%M:%S")} #{name.ljust(18, ' ')} | ".colorize(color)
        STDOUT << message
        STDOUT << "\n"
      end

      STDOUT.flush
    end
  end
end
