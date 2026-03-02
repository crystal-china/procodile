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

    getter pipe : Hash(Symbol, IO::FileDescriptor)
    @pending : Hash(Signal, Atomic(Bool))

    def initialize
      @handlers = {} of Signal => Array(Proc(Nil))
      reader, writer = IO.pipe
      @pipe = {:reader => reader, :writer => writer}

      @pending = SIGNALS.each_with_object({} of Signal => Atomic(Bool)) do |sig, hash|
        pending = Atomic(Bool).new(false)

        sig.trap do
          # 1. trap 回调里不做重活，只做“记账 + 唤醒”。
          # 2. 主循环（supervisor）被唤醒后，调用 handle 真正执行逻辑。
          # 3. 每种信号只维护一个“待处理标记”（Atomic(Bool)），不是队列。
          pending.set(true, :relaxed) # 设为 true 表示该信号待处理
          wakeup
        end

        hash[sig] = pending
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
      # 向 @pipe[:writer] 写一个字节，唤醒 watch_for_output 那边被 read block 的主循环
      @pipe[:writer].write_byte(1_u8)
    rescue IO::Error
      # Ignore wake-up failures during shutdown.
    end

    # 运行拦截的信号对应的处理函数
    def handle : Nil
      SIGNALS.each do |signal|
        next unless @pending[signal].swap(false, :acquire)

        Procodile.log nil, "system", "Supervisor received #{signal} signal"

        @handlers[signal].try &.each &.call
      end
    end
  end
end
