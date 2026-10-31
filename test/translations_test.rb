# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rake"
load File.expand_path("../Rakefile", __dir__) unless respond_to?(:translations_sweep_pr, true)

class TranslationsTest < Minitest::Test
  REPO = "teamziax/cubecraft"

  def setup
    @dir = Dir.mktmpdir("translations-test")
    @ax_bin = ENV["AX_BIN"]
    ENV["AX_BIN"] = File.join(@dir, "ax")
    @approved = []
    define_singleton_method(:actions_resolve_ref) do |_repo, number|
      { number: number.to_i, branch: "translations", sha: "abcdef1234567890", base: "production", mergeable_state: "blocked" }
    end
    runs = -> { @runs }
    define_singleton_method(:actions_runs_for_sha) { |_repo, _sha| runs.call }
    @runs = []
  end

  def teardown
    ENV["AX_BIN"] = @ax_bin
    FileUtils.rm_rf(@dir)
  end

  def fake_ax(show_out, show_code)
    File.write(ENV["AX_BIN"], <<~SH)
      #!/bin/sh
      echo "$*" >> #{@dir}/calls
      case "$1 $2" in
        "pr show") printf '%s' '#{show_out}'; exit #{show_code} ;;
      esac
      echo ok
    SH
    File.chmod(0o755, ENV["AX_BIN"])
  end

  def calls = File.exist?("#{@dir}/calls") ? File.readlines("#{@dir}/calls", chomp: true) : []

  def sweep
    result = nil
    capture_io { result = translations_sweep_pr(REPO, "8947") }
    result
  end

  def test_off_the_train_is_added_on_its_head_branch_and_given_dev
    fake_ax("ax: could not read #{REPO}#8947: #{REPO}#8947 is not in any train", 1)
    assert sweep
    dev = Reviewers.expand_all(["dev"], org: "teamziax")
    assert_equal ["pr show #{REPO} 8947", "pr add translations #{REPO} 8947", "pr assign #{REPO} 8947 #{dev.join(' ')}"], calls
  end

  def test_on_the_train_with_reviewers_is_left_alone
    fake_ax('{"intendedReviewers":["teamziax/dev"]}', 0)
    assert sweep
    assert_equal ["pr show #{REPO} 8947"], calls
  end

  def test_on_the_train_with_no_reviewers_only_gets_dev
    fake_ax('{"intendedReviewers":[]}', 0)
    assert sweep
    assert_equal 2, calls.length
    assert_match(/\Apr assign #{REPO} 8947 /, calls.last)
  end

  def test_a_train_it_cannot_read_is_a_failure_and_adds_nothing
    fake_ax("cannot reach PRTrain", 3)
    refute sweep
    assert_equal ["pr show #{REPO} 8947"], calls
  end

  def test_pending_runs_go_through_status_then_approve
    fake_ax('{"intendedReviewers":["teamziax/dev"]}', 0)
    @runs = [{ "id" => 1, "conclusion" => "action_required", "status" => "completed" }]
    invoked = []
    %w(actions:status actions:approve).each do |name|
      task = Rake::Task[name]
      task.define_singleton_method(:invoke) { |*args| invoked << [name, *args] }
    end
    assert sweep
    assert_equal [["actions:status", REPO, "8947"], ["actions:approve", REPO, "8947"]], invoked
  ensure
    %w(actions:status actions:approve).each { |name| Rake::Task[name].singleton_class.send(:remove_method, :invoke) rescue nil }
  end
end
