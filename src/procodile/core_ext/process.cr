class ::Process
  def self.fork(&block) : Process
    new Crystal::System::Process.fork { yield }
  end
end
