File.touch("Procfile")
APPS_ROOT = File.expand_path("apps", __DIR__)
require "spec"
require "yaml"
require "../src/procodile"
