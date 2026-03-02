# 信号处理程序
#
# 当一个信号被拦截后，首先，这个信号会被加入一个 QUEUE
# 每一个信号又关联一个 handlers 列表
# 当运行 #handle 方法时，会依次执行所有的处理器程序。

module Procodile
  class SignalHandler
    # 允许的信号
    SIGNALS = {
      Signal::TERM,
      Signal::USR1,
      Signal::USR2,
      Signal::INT,
      Signal::HUP,
    }

    QUEUE = [] of Signal

    getter pipe : Hash(Symbol, IO::FileDescriptor)

    def initialize
      @handlers = {} of Signal => Array(Proc(Nil))
      reader, writer = IO.pipe
      @pipe = {:reader => reader, :writer => writer}

      SIGNALS.each do |signal|
        signal.trap do
          QUEUE << signal
          wakeup
        end
      end
    end

    # 关联信号和处理函数
    #
    # 这个在 SignalHandler 对象创建之后，被手动调用
    def register(signal : Signal, &block : ->) : Nil
      @handlers[signal] ||= [] of Proc(Nil)

      @handlers[signal] << block
    end

    def wakeup : Nil
      # 向 @pipe[:writer] 写一个字节，唤醒 watch_for_output 那边被 pipe[:reader].read_byte block 的主循环
      @pipe[:writer].write_byte(1_u8)
    rescue IO::Error
      # Ignore wake-up failures during shutdown.
    end

    # 运行拦截的信号对应的处理函数
    def handle : Nil
      if (signal = QUEUE.shift?)
        Procodile.log nil, "system", "Supervisor received #{signal} signal"
        @handlers[signal].try &.each &.call
      end
    end
  end
end
