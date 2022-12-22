module Procodile
  class SignalHandler
    QUEUE   = [] of Signal
    SIGNALS = {
      Signal::TERM,
      Signal::USR1,
      Signal::USR2,
      Signal::INT,
      Signal::HUP,
    }

    getter pipe : Hash(Symbol, IO::FileDescriptor)

    def initialize
      @handlers = {} of Signal => Array(Proc(Nil))
      reader, writer = IO.pipe
      @pipe = {:reader => reader, :writer => writer}

      SIGNALS.each do |sig|
        sig.trap do
          QUEUE << sig
          notice
        end
      end
    end

    def start
      spawn do
        loop do
          handle
          sleep 1
        end
      end
    end

    def register(signal : Signal, &block) : Array(Proc(Nil))
      @handlers[signal] ||= [] of Proc(Nil)
      @handlers[signal] << block
    end

    def notice
      @pipe[:writer].write(".".to_slice)
    end

    def handle
      if signal = QUEUE.shift?
        Procodile.log nil, "system", "Supervisor received #{signal} signal"
        @handlers[signal].try &.each(&.call)
      end
    end
  end
end
