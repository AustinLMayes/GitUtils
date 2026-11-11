# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rake"
load File.expand_path("../Rakefile", __dir__)

class ForcePushGuardTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("force-push-guard")
    sh(@tmp, "git", "init", "-q", "--bare", "-b", "main", "origin.git")
    sh(@tmp, "git", "clone", "-q", "origin.git", "local")
    @local = File.join(@tmp, "local")
    sh(@local, "git", "config", "user.name", "Test")
    sh(@local, "git", "config", "user.email", "test@example.com")
    sh(@local, "git", "commit", "-q", "--allow-empty", "-m", "base")
    sh(@local, "git", "checkout", "-q", "-b", "austin/topic")
    sh(@local, "git", "commit", "-q", "--allow-empty", "-m", "one")
    sh(@local, "git", "push", "-q", "origin", "austin/topic")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def sh(dir, *cmd)
    system(*cmd, chdir: dir, out: File::NULL, err: File::NULL, exception: true)
  end

  def kept(*branches)
    out = nil
    capture_io { out = Dir.chdir(@local) { skip_unseen_remote_heads(branches) } }
    out
  end

  def push_from_elsewhere
    sh(@local, "git", "checkout", "-q", "--detach")
    sh(@local, "git", "commit", "-q", "--allow-empty", "-m", "review fix")
    sh(@local, "git", "push", "-q", "origin", "HEAD:refs/heads/austin/topic")
    sh(@local, "git", "checkout", "-q", "austin/topic")
  end

  def test_a_head_pushed_from_elsewhere_is_refused
    push_from_elsewhere

    assert_empty kept("austin/topic")
  end

  def test_a_head_pushed_from_elsewhere_then_merged_goes_through
    push_from_elsewhere
    sh(@local, "git", "commit", "-q", "--allow-empty", "-m", "local")
    sh(@local, "git", "fetch", "-q", "origin")
    sh(@local, "git", "merge", "-q", "--no-edit", "origin/austin/topic")

    assert_equal ["austin/topic"], kept("austin/topic")
  end

  def test_an_amend_after_the_push_goes_through
    sh(@local, "git", "commit", "-q", "--amend", "--allow-empty", "-m", "one, amended")

    assert_equal ["austin/topic"], kept("austin/topic")
  end

  def test_unpushed_commits_on_top_go_through
    sh(@local, "git", "commit", "-q", "--allow-empty", "-m", "two")

    assert_equal ["austin/topic"], kept("austin/topic")
  end

  def test_a_branch_origin_lacks_goes_through
    sh(@local, "git", "checkout", "-q", "-b", "austin/new")

    assert_equal ["austin/new"], kept("austin/new")
  end
end
