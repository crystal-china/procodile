module Procodile
  module ProcessSelector
    PROCESS_INSTANCE_REGEX = /\A(.+)\.(\d+)\z/

    def self.parse(name : String) : Tuple(String, Int32?)
      if (match = name.match(PROCESS_INSTANCE_REGEX))
        {match[1], match[2].to_i32}
      else
        {name, nil}
      end
    end
  end
end
