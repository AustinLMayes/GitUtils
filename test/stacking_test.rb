# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "rake"
load File.expand_path("../Rakefile", __dir__)

class StackingTest < Minitest::Test
  def entry(label, title, description = "", commit: "#{label.tr("/", "")}0000000000")
    { commit: commit, label: label, title: title, subject: "#{label} #{title}", description: description, branch: "stacks/austin/#{label}" }
  end

  def problems(plan)
    Linear::Teams.stub(:keys, %w[ROC CCENG]) { stack_plan_problems(plan) }
  end

  def test_a_clean_stack_has_no_problems
    assert_empty problems([entry("flags/a", "Add a (ROC-1432)"), entry("flags/b", "Add b (ROC-1433)")])
  end

  def test_two_commits_on_one_token_push_over_each_other
    found = problems([entry("flags/openfeature", "Add a", commit: "aaaaaaaaaa"), entry("flags/openfeature", "Add b", commit: "bbbbbbbbbb")])
    assert_equal 1, found.length
    assert_match "stacks/austin/flags/openfeature", found.first
    assert_match "aaaaaaaaaa, bbbbbbbbbb", found.first
  end

  def test_a_slashless_first_token_is_refused
    found = problems([entry("Fix", "the thing"), entry("fixup!", "flags/a Add a")])
    assert_equal 2, found.length
    assert(found.all? { |p| p.include?("<label>/") })
  end

  def test_one_umbrella_id_across_the_identity_pilot_is_refused
    plan = (1..5).map { |n| entry("identity/p#{n}", "Step #{n} (ROC-1)") }
    found = problems(plan)
    assert_equal 1, found.length
    assert_match "ROC-1 is the only Linear id on 5 commits", found.first
  end

  def test_an_id_in_the_body_counts
    found = problems([entry("a/one", "One", "ROC-7"), entry("a/two", "Two (ROC-7)")])
    assert_match "ROC-7", found.join
  end

  def test_a_shared_parent_beside_each_child_id_passes
    assert_empty problems([entry("a/one", "One (ROC-1432) ROC-1431"), entry("a/two", "Two (ROC-1433) ROC-1431")])
  end

  def test_tokens_that_are_not_linear_teams_are_ignored
    assert_empty problems([entry("enc/a", "Force UTF-8"), entry("enc/b", "Read UTF-8 too")])
  end

  def test_validate_stops_before_any_push
    plan = [entry("x/a", "A"), entry("x/a", "B")]
    out, = capture_io do
      assert_raises(SystemExit) { Linear::Teams.stub(:keys, []) { validate_stack_plan(plan) } }
    end
    assert_match "Not pushing this stack", out
  end

  def test_stack_source_target_strips_the_ref_prefixes
    %w[fix/chat stacks/austin/fix/chat origin/stacks/austin/fix/chat refs/heads/stacks/austin/fix/chat refs/remotes/origin/stacks/austin/fix/chat].each do |arg|
      assert_equal "fix/chat", stack_source_target(arg)
    end
    assert_equal "Fix message rendering", stack_source_target(" Fix message rendering ")
  end

  def test_stack_sources_finds_the_source_commit_from_any_end
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        git = ->(*args) { Git.ok?(nil, *args) or raise "git #{args.join(" ")}" }
        git.("init", "-q", "-b", "production")
        git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
        git.("checkout", "-q", "-b", "austin/s/whitelist")
        git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "wl/shared Add shared accounts")
        git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "wl/2fa Add 2FA ranges")
        git.("checkout", "-q", "-b", "austin/u/bugs", "production")
        git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "fix/chat Fix message rendering")
        git.("checkout", "-q", "-b", "austin/wl-shared", "production")

        hits = nil
        capture_io { hits = stack_sources("wl/2fa") }
        assert_equal [["austin/s/whitelist", 2, 2]], hits.map { |h| [h[:branch], h[:position], h[:of]] }
        assert_equal Git.out(nil, "rev-parse", "austin/s/whitelist"), hits.first[:sha]

        capture_io { hits = stack_sources(stack_source_target("origin/stacks/austin/fix/chat")) }
        assert_equal ["austin/u/bugs"], hits.map { |h| h[:branch] }

        capture_io { hits = stack_sources("add shared accounts") }
        assert_equal ["wl/shared Add shared accounts"], hits.map { |h| h[:subject] }

        capture_io { hits = stack_sources("wl") }
        assert_empty hits
      end
    end
  end

  def test_warns_when_the_train_has_no_reviewers_for_a_pr
    out = with_reviewers({ 7 => [], 8 => ["teamziax/developers"] }, tasks: ["stacking:diff"]) do
      warn_unassigned([7, 8], "stacking:assign", "austin/s/x")
    end
    assert_match "No reviewers on #7,", out
    refute_match "#8", out
    assert_match "fgutils 'stacking:assign[dev]'", out
  end

  def test_quiet_when_assign_runs_in_the_same_invocation
    out = with_reviewers({ 7 => [] }, tasks: ["stacking:diff", "stacking:assign[dev]"]) do
      warn_unassigned([7], "stacking:assign", "austin/s/x")
    end
    assert_empty out
  end

  def test_quiet_when_the_train_cant_say
    out = with_reviewers({ 7 => nil }, tasks: ["prs:submit"]) { warn_unassigned([7], "prs:assign", "austin/x") }
    assert_empty out
  end

  def with_reviewers(map, tasks:, &block)
    out, = capture_io do
      Rake.application.stub(:top_level_tasks, tasks) do
        stub(:train_reviewers, ->(n) { map[n] }, &block)
      end
    end
    out
  end
end
