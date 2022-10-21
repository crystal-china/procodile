module Procodile
  module Rbenv
    #
    # If procodile is executed through rbenv it will pollute our environment which means that
    # any spawned processes will be invoked with procodile's ruby rather than the ruby that
    # the application wishes to use
    #
    def self.without(&)
      previous_environment = ENV.select { |k, v| k =~ /\A(RBENV_)/ }
      if !previous_environment.empty?
        previous_environment.each { |key, value| ENV[key] = nil }
        previous_environment["PATH"] = ENV["PATH"]
        ENV["PATH"] = ENV["PATH"].split(":").reject { |p| p.include?(".rbenv/versions") }.join(":")
      end
      yield
    ensure
      previous_environment.each do |key, value|
        ENV[key] = value
      end
    end
  end
end
