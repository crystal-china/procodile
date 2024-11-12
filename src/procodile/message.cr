module Procodile
  module Message
    def self.parse(message : Supervisor::Message) : String
      case message.type
      in .not_running?
        "#{message.instance} is not running (#{message.status})"
      in .incorrect_quantity?
        "#{message.process} has #{message.current} instances (should have #{message.desired})"
      end
    end
  end
end
