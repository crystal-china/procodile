# 信号处理程序
#
# 当一个信号被拦截后，会向 self-pipe 写入一个字节用于唤醒主循环
# 每一个信号又关联一个 handlers 列表
# 当运行 #handle 方法时，会依次执行所有的处理器程序。

module Procodile
  class SignalHandler
    Wakeup = 0_u8

    # 信号处理回调最稳的实践是：只做极简、可重入、无复杂状态访问的动作，
    # 因此，这里引入 signal code
    enum SignalCode : UInt8
      Term   = 1_u8
      Usr1   = 2_u8
      Usr2   = 3_u8
      Int    = 4_u8
      Hup    = 5_u8

      def signal : Signal
        case self
        in Term
          Signal::TERM
        in Usr1
          Signal::USR1
        in Usr2
          Signal::USR2
        in Int
          Signal::INT
        in Hup
          Signal::HUP
        end
      end
    end

    getter pipe : Hash(Symbol, IO::FileDescriptor)

    def initialize
      @handlers = {} of Signal => Array(Proc(Nil))
      reader, writer = IO.pipe
      @pipe = {:reader => reader, :writer => writer}

      SignalCode.each do |code|
        code.signal.trap { wakeup(code) }
      end
    end

    # 关联信号和处理函数
    #
    # 这个在 SignalHandler 对象创建之后，被手动调用
    def register(signal : Signal, &block : ->) : Nil
      @handlers[signal] ||= [] of Proc(Nil)

      @handlers[signal] << block
    end

    # 普通唤醒（非信号）
    def wakeup : Nil
      # 向 @pipe[:writer] 写一个字节，唤醒 watch_for_output 那边被 pipe[:reader].read_byte block 的主循环
      @pipe[:writer].write_byte(Wakeup)
    rescue IO::Error
      # Ignore wake-up failures during shutdown.
    end

    # trap 路径中不要分配复杂对象，只写一个字节到 pipe
    private def wakeup(code : SignalCode) : Nil
      @pipe[:writer].write_byte(code.value)
    rescue IO::Error
      # Ignore wake-up failures during shutdown.
    end

    # 运行拦截的信号对应的处理函数
    def handle(byte : UInt8) : Nil
      return if byte == Wakeup

      signal = SignalCode.from_value(byte).signal

      Procodile.log nil, "system", "Supervisor received #{signal} signal"

      @handlers[signal].try &.each &.call
    end
  end
end
