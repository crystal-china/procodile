module Procodile
  class SignalHandler
    QUEUE = [] of String

    getter pipe : Hash(Symbol, IO::FileDescriptor)

    def self.queue : Array(String)
      # Thread.main[:signal_queue] ||= [] of String
      QUEUE
    end

    def initialize(*signals)
      @handlers = {} of String => Array(Proc(Nil))
      reader, writer = IO.pipe
      @pipe = {:reader => reader, :writer => writer}
      signals.each do |sig|
        sig.trap { SignalHandler.queue << sig.to_s; notice }
      end
    end

    def start : Nil
      Thread.new do
        loop do
          handle
          sleep 1
        end
      end
    end

    def register(name, &block) : Array(Proc(Nil))
      @handlers[name] ||= [] of Proc(Nil)
      @handlers[name] << block
    end

    def notice : Nil
      @pipe[:writer].write(".".to_slice)
    end

    def handle : Nil
      if signal = self.class.queue.shift?
        Procodile.log nil, "system", "Supervisor received #{signal} signal"
        @handlers[signal].try &.each(&.call)
      end
    end
  end
end
