require "option_parser"
require "file_utils"
require "yaml"
require "./procodile/cli"
require "./procodile/version"
require "./procodile/config"
require "./procodile/app_determination"
require "./procodile/error"
require "./procodile/color"

module Procodile
  def self.root
    File.expand_path("..", __DIR__)
  end

  def self.bin_path
    File.join(root, "bin", "procodile")
  end
end

ORIGINAL_ARGV = ARGV.join(" ")
command = ARGV[0]? || "help"
options = {} of Symbol => String
cli = Procodile::CLI.new

OptionParser.parse do |parser|
  parser.banner = "Usage: procodile #{command} [options]"

  parser.on("-r", "--root PATH", "The path to the root of your application") do |root|
    options[:root] = root
  end

  parser.on("--procfile PATH", "The path to the Procfile (defaults to: Procfile)") do |path|
    options[:procfile] = path
  end

  parser.invalid_option do |flag|
    STDERR.puts "Invalid option: #{flag}.\n\n"
    STDERR.puts parser
    exit 1
  end

  parser.missing_option do |flag|
    STDERR.puts "Missing option for #{flag}\n\n"
    STDERR.puts parser
    exit 1
  end

  if cli.class.commands[command]? && (option_block = cli.class.commands[command].options)
    option_block.call(parser, cli)
  end
end

# Get the global configuration file data
global_config_path = ENV["PROCODILE_CONFIG"]? || "Procfile.options.global"

if File.file?(global_config_path)
  global_config = Procodile::ProcfileOption.from_yaml(File.read(global_config_path))
end

# Create a determination to work out where we want to load our app from
ap = Procodile::AppDetermination.new(FileUtils.pwd, options[:root]?, options[:procfile]?, global_config)

begin
  cli.config = Procodile::Config.new(ap.root.not_nil!, ap.procfile)
  cli.dispatch(command)
rescue ex : Procodile::Error
  STDERR.puts "Error: #{ex.message}".color(31)
  exit 1
end
