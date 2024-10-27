# 信号处理程序
#
# 当一个信号被拦截后，首先，这个信号会被加入一个 QUEUE

module Procodile
  class SignalHandler
    # 保存用户发送的信号.
    QUEUE = [] of Signal

    # 允许的信号
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

    # 关联信号和处理函数
    #
    # 这个在 SignalHandler 对象创建之后，被手动调用
    def register(signal : Signal, &block)
      @handlers[signal] ||= [] of Proc(Nil)
      @handlers[signal] << block
    end

    def notice
      @pipe[:writer].write(".".to_slice)
    end

    # 运行拦截的信号对应的处理函数
    def handle
      if (signal = QUEUE.shift?)
        Procodile.log nil, "system", "Supervisor received #{signal} signal"
        @handlers[signal].try &.each(&.call)
      end
    end
  end
end
