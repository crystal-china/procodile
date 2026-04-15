module Procodile
  private class_getter logger_mutex : Mutex { Mutex.new }

  def self.log(name : String, text : String, color : Colorize::ColorANSI? = nil) : Nil
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

  def self.log_exception(name : String, prefix : String, ex : Exception, *, backtrace_limit : Int32? = nil) : Nil
    log name, "#{prefix}: #{ex.class}: #{ex.message}"

    if (backtrace = ex.backtrace)
      lines = backtrace_limit ? backtrace.first(backtrace_limit.not_nil!) : backtrace
      lines.each { |line| log name, "=> #{line}" }
    end
  end
end
