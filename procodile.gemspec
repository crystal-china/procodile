require_relative "./lib/procodile/version"
Gem::Specification.new do |s|
  s.name          = "procodile"
  s.description   = "A sophisticated process manager for applications running on Linux & macOS."
  s.summary       = "This gem will help you run processes from a Procfile on Linux/macOS machines in the background or the foreground."
  s.homepage      = "https://github.com/adamcooke/procodile"
  s.version       = Procodile::VERSION
  s.files         = Dir.glob("{lib,bin}/**/*")
  s.require_paths = ["lib"]
  s.authors       = ["Adam Cooke"]
  s.email         = ["me@adamcooke.io"]
  s.licenses      = ["MIT"]
  s.cert_chain    = ["certs/adamcooke.pem"]
  s.signing_key   = File.expand_path("~/.gem/signing-key.pem") if $0.end_with?("gem")
  s.bindir = "bin"
  s.executables << "procodile"
  s.add_runtime_dependency "json"
  s.metadata["rubygems_mfa_required"] = "true"
end
