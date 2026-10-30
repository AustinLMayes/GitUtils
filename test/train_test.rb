# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "rake"
load File.expand_path("../Rakefile", __dir__) unless respond_to?(:train, true)

class TrainTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("train-test")
    @ax_bin = ENV["AX_BIN"]
    ENV["AX_BIN"] = File.join(@dir, "ax")
  end

  def teardown
    ENV["AX_BIN"] = @ax_bin
    FileUtils.rm_rf(@dir)
  end

  def fake_ax(out, code)
    File.write(ENV["AX_BIN"], "#!/bin/sh\necho \"$*\" > #{@dir}/argv\nprintf '%s' '#{out}'\necho oops >&2\nexit #{code}\n")
    File.chmod(0o755, ENV["AX_BIN"])
  end

  def train_with(out, code)
    fake_ax(out, code)
    result = nil
    printed, = capture_io { result = train("add", "o/r", 7) }
    [result, printed]
  end

  def test_exit_0_moved_and_says_what
    result, printed = train_with("added #7", 0)
    assert_equal true, result
    assert_match "[INFO]", printed
    assert_match "added #7", printed
    assert_equal "add o/r 7\n", File.read(File.join(@dir, "argv"))
  end

  def test_no_change_is_info_not_a_warning
    result, printed = train_with("already tracked", Ax::TRAIN_NO_CHANGE)
    assert_equal false, result
    assert_match "[INFO]", printed
  end

  def test_unreachable_is_down
    result, printed = train_with("train is not running", Ax::TRAIN_UNREACHABLE)
    assert_equal :down, result
    assert_match "[WARNING]", printed
    assert_match "train is not running", printed
  end

  def test_any_other_exit_warns_with_stderr_merged_in
    result, printed = train_with("", 1)
    assert_equal false, result
    assert_match "oops", printed
  end

  def test_a_missing_ax_still_raises
    ENV["AX_BIN"] = File.join(@dir, "nope")
    assert_raises(Command::Unavailable) { capture_io { train("add", "o/r", 7) } }
  end

  def test_train_reviewers_reads_intended_reviewers
    fake_ax('{"intendedReviewers": ["teamziax/developers"]}', 0)
    Git.stub(:repo_name_with_org, "o/r") do
      assert_equal ["teamziax/developers"], train_reviewers(7)
    end
    assert_equal "pr show o/r 7\n", File.read(File.join(@dir, "argv"))
  end

  def test_train_reviewers_is_nil_when_ax_fails_or_answers_junk
    Git.stub(:repo_name_with_org, "o/r") do
      fake_ax("{}", 1)
      assert_nil train_reviewers(7)
      fake_ax("not json", 0)
      assert_nil train_reviewers(7)
      ENV["AX_BIN"] = File.join(@dir, "nope")
      assert_nil train_reviewers(7)
    end
  end
end
