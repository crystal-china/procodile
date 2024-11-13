class ::Process
  # override ::Process.fork in stdlib for suppress the warning message.
  def self.fork(&) : Process
    new Crystal::System::Process.fork { yield }
  end
end
