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
    global_options = {
      root:     "/app",
      procfile: "Procfile",
    }.to_yaml

    ap = Procodile::AppDetermination.new(
      pwd: "/myapps",
      given_root: nil,
      given_procfile: nil,
      global_options: Procodile::ProcfileOption.from_yaml(global_options)
    )
    ap.root.should eq "/app"
    ap.procfile.should eq "/app/Procfile"
  end
end
