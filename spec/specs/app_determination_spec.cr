require "../spec_helper"
require "../../src/procodile/app_determination"

describe Procodile::AppDetermination do
  it "should allow root and procfile to be provided" do
    ap = Procodile::AppDetermination.new(
      pwd: "/",
      given_root: "/app",
      given_procfile: "Procfile",
    )
    ap.root.should eq "/app"
    ap.procfile.should eq "/app/Procfile"
  end

  it "should normalize the trailing slashes" do
    ap = Procodile::AppDetermination.new(
      pwd: "/",
      given_root: "/app/",
      given_procfile: "Procfile",
    )
    ap.root.should eq "/app"
    ap.procfile.should eq "/app/Procfile"
  end

  it "should allow only given_root provided" do
    ap = Procodile::AppDetermination.new(
      pwd: "/home",
      given_root: "/some/app",
      given_procfile: nil,
    )
    ap.root.should eq "/some/app"
    ap.procfile.should be_nil
  end

  it "should allow only given_procfile provided" do
    ap = Procodile::AppDetermination.new(
      pwd: "/app",
      given_root: nil,
      given_procfile: "/myapps/Procfile",
    )
    ap.root.should eq "/myapps"
    ap.procfile.should eq "/myapps/Procfile"
  end

  it "should use global_options" do
    yaml = <<-'HEREDOC'
-
  name: Widgets App
  root: /path/to/widgets/app
-
  name: Another App
  root: /path/to/another/app
HEREDOC

    ap = Procodile::AppDetermination.new(
      pwd: "/myapps",
      given_root: nil,
      given_procfile: nil,
      global_options: Array(Procodile::Config::GlobalOption).from_yaml(yaml)
    )
    ap.set_app_id_and_find_root_and_procfile(1)
    ap.root.should eq "/path/to/another/app"
    ap.procfile.should be_nil
  end
end
