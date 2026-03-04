File.touch("Procfile")
APPS_ROOT = File.expand_path("apps", __DIR__)
require "spec"
require "yaml"
require "../src/procodile"

def wait_until(timeout : Time::Span, interval : Time::Span = 10.milliseconds, &block : -> Bool) : Bool
  deadline = Time.instant + timeout
  until yield
    return false if Time.instant >= deadline
    sleep interval
  end
  true
end
