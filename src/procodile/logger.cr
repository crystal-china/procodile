require "./color"

module Procodile
  def self.mutex : Mutex
    @@mutex ||= Mutex.new
  end

  def self.log(color, name, text) : Nil
    mutex.synchronize do
      text.to_s.lines.map(&.chomp).each do |message|
        output = ""
        output += "#{Time.local.to_s("%H:%M:%S")} #{name.ljust(18, ' ')} | ".color(color)
        output += message
        STDOUT.puts output
        STDOUT.flush
      end
    end
  end
end
