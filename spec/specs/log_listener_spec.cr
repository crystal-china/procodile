require "../spec_helper"

describe "log listener lifecycle" do
  it "cleans up reader after pipe closes" do
    config = Procodile::Config.new(root: File.join(APPS_ROOT, "basic"))
    run_options = Procodile::Supervisor::RunOptions.new(
      respawn: nil,
      stop_when_none: nil,
      force_single_log: nil,
      port_allocations: nil,
      proxy: nil,
      foreground: false
    )
    supervisor = Procodile::Supervisor.new(config, run_options)

    process = config.processes.values.first
    instance = process.create_instance(supervisor)

    reader, writer = IO.pipe

    # Attach reader to supervisor and immediately close the writer to trigger EOF.
    supervisor.add_instance(instance, reader)
    writer.close

    # Ensure the reader is removed after EOF is observed.
    wait_until(1.second) { !supervisor.readers.has_key?(reader) }.should be_true
  end
end
