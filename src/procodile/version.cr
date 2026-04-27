module Procodile
  VERSION = {{
              `shards version "#{__DIR__}"`.chomp.stringify +
              " (rev " +
              `git rev-parse --short HEAD`.chomp.stringify +
              ")"
            }}
end
