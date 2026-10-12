require "spec"
require "../src/spawn"

# `Spawn` is the only way this app starts an external program (ImageMagick,
# hyprctl). Its failure modes are quiet — a wrong exit-code decode or a lost
# stream turns every thumbnail into a mysterious error — so pin the behaviour.
describe Spawn do
  it "captures stdout and reports success" do
    result = Spawn.run("/bin/sh", ["-c", "printf 'hello'"])
    result.success?.should be_true
    result.output.should eq "hello"
    result.exit_code.should eq 0
  end

  it "captures stderr and the exit code of a failing command" do
    result = Spawn.run("/bin/sh", ["-c", "printf 'boom' >&2; exit 3"])
    result.success?.should be_false
    result.exit_code.should eq 3
    result.error.should eq "boom"
    result.message.should eq "boom"
  end

  it "inherits the parent environment" do
    result = Spawn.run("/bin/sh", ["-c", "printf '%s' \"$HOME\""])
    result.output.should eq ENV["HOME"]
  end

  it "raises when the program cannot be started at all" do
    expect_raises(Spawn::Error, /cannot start/) do
      Spawn.run("/nonexistent/binary-#{Process.pid}", [] of String)
    end
  end
end
