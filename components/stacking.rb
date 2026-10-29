# Source-commit -> { commit:, branch:, title:, description: }. First whitespace-token of
# the subject becomes the sub-branch suffix; the rest becomes the PR title.
def plan_stacked_entry(commit)
  msg = Git.commit_message(commit)
  subject = msg[:title].to_s.strip
  body = msg[:body].to_s
  parts = subject.split(/\s+/, 2)
  first_token = parts[0].to_s
  rest = parts[1].to_s.strip
  if first_token.empty? || rest.empty?
    error "Commit #{commit[0, 10]} has subject #{subject.inspect}; expected `<first-token> <rest>` (e.g. `ab/lol Some change`)"
  end
  branch = "stacks/austin/#{first_token}"
  { commit: commit, branch: branch, title: rest, description: body.strip, subject: subject, label: first_token }
end

# Subjects that read like a repair of something rather than a change to something. Deliberately
# broad; a match alone never warns — it has to also point at an ancestor in the same stack.
DEFECT_SUBJECT_PATTERN = /\A(?:fix|hotfix|repair|correct|revert|undo|stop|prevent|resolve|patch|restore|unbreak|guard|no longer|don'?t)(?:s|es|ed)?\b/i

def commit_file_list(commit)
  `git diff-tree --no-commit-id --name-only -r #{commit}`.split("\n").map(&:strip).reject(&:empty?)
end

# `strings/legacy-codes` and `strings/generic-links` are the same subject area and the label's
# first segment is the only thing that says so — #7292 repaired the commit below it while sharing
# not one file with it, so file overlap on its own would have missed the case this check exists for.
def label_namespace(label)
  label.to_s.split("/").first.to_s
end

# These name the KIND of change, not the area it touches, so two of them in one stack say nothing
# about whether either repairs the other. Measured over cubecraft production: 12 real `fix/*` runs,
# 60 commit pairs, zero shared files — every one an independent pre-existing fix that belongs
# stacked. Without this the check fires ~28 times on one 8-commit `fix/*` stack and gets ignored.
GENERIC_LABEL_NAMESPACES = %w[fix fixes hotfix chore clean cleanup misc wip nit tmp revert].freeze

def topical_namespace?(label)
  ns = label_namespace(label)
  !ns.empty? && !GENERIC_LABEL_NAMESPACES.include?(ns.downcase)
end

# P1 (cube-commit-testing): a fix for a defect introduced by commit N lands at or before N, amended
# in — not stacked on top of it. #7292 is the case: its repair sat in review above the commit whose
# breakage it fixed, and that breakage reached production alone.
def downstream_fix_findings(plan)
  files = plan.to_h { |entry| [entry[:commit], commit_file_list(entry[:commit])] }
  plan.each_with_index.filter_map do |entry, index|
    ancestors = plan[0...index]
    next if ancestors.empty?
    autosquash = entry[:label].to_s.match?(/\A(?:fixup|squash)!\z/i)
    next unless autosquash || entry[:title].to_s.match?(DEFECT_SUBJECT_PATTERN)
    targets = ancestors.filter_map do |ancestor|
      reasons = []
      shared = files[entry[:commit]] & files[ancestor[:commit]]
      reasons << "shares #{shared.length} changed file(s): #{shared.first(3).join(", ")}" unless shared.empty?
      if autosquash
        named = entry[:title].to_s.start_with?(ancestor[:label].to_s) ||
                entry[:title].to_s.strip == ancestor[:title].to_s.strip
        reasons << "named by the autosquash subject" if named
      elsif topical_namespace?(entry[:label]) && label_namespace(entry[:label]) == label_namespace(ancestor[:label])
        reasons << "same label namespace `#{label_namespace(entry[:label])}/`"
      end
      reasons.empty? ? nil : { entry: ancestor, reasons: reasons }
    end
    next if targets.empty? && !autosquash
    { entry: entry, targets: targets, autosquash: autosquash }
  end
end

def report_stack_ordering(findings)
  return if findings.empty?
  warning "Stack ordering: #{findings.length} commit(s) look like a fix for something BELOW them in this stack."
  findings.each do |finding|
    entry = finding[:entry]
    warning "  #{entry[:commit][0, 10]} #{entry[:subject]}"
    if finding[:autosquash]
      warning "    `#{entry[:label]}` is an autosquash marker — this run will push it as #{entry[:branch]} and open a PR for it"
    end
    finding[:targets].each do |target|
      warning "    over #{target[:entry][:commit][0, 10]} #{target[:entry][:subject]}"
      target[:reasons].each { |reason| warning "         #{reason}" }
    end
    next if finding[:targets].empty?
    warning "    A fix for a defect introduced by commit N lands at or before N: `gamend #{finding[:targets].last[:entry][:commit][0, 10]}`,"
    warning "    or slot it in BELOW that commit if it stands alone. Stacked above, it ships after the breakage does."
  end
end

def sync_stacked_pr(entry, base)
  branch = entry[:branch]
  pr_number = GitHub.open_pr_number(branch)
  if pr_number.nil?
    created = GitHub.make_pr(entry[:title], base: base, head: branch, body: entry[:description], draft: true)
    return created.nil? ? nil : created.to_i
  end
  unless system("gh", "pr", "edit", pr_number.to_s, "--repo", Git.repo_name_with_org,
                "--title", entry[:title], "--body", entry[:description], out: File::NULL, err: File::NULL)
    warning "Failed to sync PR ##{pr_number} title/body via gh pr edit"
  end
  pr_number
end

# GitHub refuses a base change on a PR inside one of its stacks, and it moves the bases itself as
# the stack merges. So only a real disagreement gets touched, and the stack is taken apart first.
def reconcile_stacked_bases(expected_bases, states)
  wrong = expected_bases.select { |n, base| states[n] && states[n]["baseRefName"] != base }
  return if wrong.empty?
  wrong.keys.filter_map { |n| states[n].dig("stack", "number") }.uniq.each do |stack|
    info "Unstacking GitHub stack ##{stack} to retarget ##{wrong.keys.join(", #")}"
    unless system("gh", "stack", "unstack", stack.to_s)
      warning "gh stack unstack #{stack} failed"
      next
    end
    states.each_value { |s| s["stack"] = nil if s.dig("stack", "number") == stack }
  end
  wrong.each do |n, base|
    info "Retargeting ##{n} onto #{base}"
    next if system("gh", "pr", "edit", n.to_s, "--repo", Git.repo_name_with_org, "--base", base, out: File::NULL, err: File::NULL)
    warning "Failed to retarget PR ##{n} onto #{base}"
  end
end

def already_in_base?(commit, base)
  return true if system("git", "merge-base", "--is-ancestor", commit, "origin/#{base}")
  `git cherry origin/#{base} #{commit} #{commit}^`.start_with?("-")
end

# GitHub rebases the rest of a stack itself when the bottom PR merges, and repoclean rebases the
# source branch; both change the sha and neither changes the patch. Pushing on a sha mismatch alone
# undid GitHub's rebase every run. Same patch on the same parent is the same branch; the parent
# check is what catches a reorder, where every patch survives and the chain still changed.
def matching_remote_sha(branch, commit, parent)
  remote = GitHub.remote_sha(branch)
  return nil if remote.nil?
  return remote if remote == commit
  return nil unless system("git", "fetch", "-q", "origin", branch, out: File::NULL, err: File::NULL)
  remote_parent = `git rev-parse FETCH_HEAD^`.strip
  remote_parent == (parent || `git rev-parse #{commit}^`.strip) && patch_id("FETCH_HEAD") == patch_id(commit) ? remote : nil
end

def patch_id(rev)
  `git diff-tree -p #{rev}^ #{rev} | git patch-id --stable`.split(" ").first
end

def remote_stacked_branches
  `git ls-remote --heads origin 'refs/heads/stacks/austin/*'`.split("\n").filter_map do |line|
    ref = line.split(/\s+/)[1].to_s
    ref.sub("refs/heads/", "") unless ref.empty?
  end
end

namespace :stacking do
  def base_stacking_branch
    ENV["MAIN_BRANCH"] || "production"
  end

  def get_branches(args)
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      if args.extras[0] == "all" && args.extras[1].nil?
        branches = Git.find_branches("austin/s/.*$")
      else
        branches = Git.find_branches_multi(args.extras)
      end
    end
    branches
  end

  desc "Given the diff of the current branch, create pull requests for each commit in the diff"
  task diff: :before do |task, args|
    current = Git.current_branch
    Git.ensure_clean
    branches = get_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      Git.ensure_clean
      Git.push(force: true)
      create_stacked_prs(base_stacking_branch, branch)
    end
    system "git checkout #{current}"
  end

  desc "Cherry-pick every stacked commit onto the dev branch, push it, and move each PR to testing"
  task to_testing: :before do |task, args|
    branches = get_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      commits = Git.my_commits_between(base_stacking_branch, branch, "austin")
      next if commits.empty?
      system "git", "checkout", $dev_branch
      Git.ensure_clean
      unless system "git", "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", *commits
        system "git", "cherry-pick", "--abort"
        system "git", "checkout", branch
        error "Cherry-pick failed"
      end
      Git.push
      system "git", "checkout", branch
      Git.ensure_clean
      pr_numbers = []
      commits.each do |commit|
        pr_number = get_stacked_pr_number(commit)
        pr_numbers << pr_number unless pr_number.nil?
      end
      if pr_numbers.empty?
        warning "No stacked PRs found for branch #{branch}"
      else
        results = pr_numbers.map do |pr_number|
          train("pr", "unpause", Git.repo_name_with_org, pr_number)
          [pr_number, train("pr", "to-testing", Git.repo_name_with_org, pr_number)]
        end
        report_train_results(results, "Queued for testing")
        info "Moved PR ##{pr_numbers.join(", ")} to testing"
      end
    end
  end

  desc "Resolve all open review conversations on every stacked PR for the given branch(es)"
  task resolve: :before do |task, args|
    branches = get_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      commits = Git.my_commits_between(base_stacking_branch, branch, "austin")
      next if commits.empty?
      pr_numbers = []
      commits.each do |commit|
        pr_number = get_stacked_pr_number(commit)
        pr_numbers << pr_number unless pr_number.nil?
      end
      if pr_numbers.empty?
        warning "No stacked PRs found for branch #{branch}"
      else
        results = pr_numbers.map { |n| [n, train("pr", "resolve", Git.repo_name_with_org, n)] }
        report_train_results(results, "Resolved conversations on")
      end
    end
  end

  desc "Assign reviewers (team / person shorthands) to every PR in the current stack via PRTrain"
  task :assign, [:handles] => :before do |task, args|
    handles = [args[:handles], *args.extras].compact.reject(&:empty?)
    raise "Usage: stacking:assign[<handle>[,<handle>...]]" if handles.empty?
    expanded =
      begin
        Reviewers.expand_all(handles, org: Git.repo_org)
      rescue Reviewers::UnknownHandle => e
        error e.message
      end
    branch = Git.current_branch
    commits = Git.my_commits_between(base_stacking_branch, branch, "austin")
    if commits.empty?
      warning "No stacked commits between #{base_stacking_branch} and #{branch}; nothing to assign"
      next
    end
    pr_numbers = commits.filter_map { |c| get_stacked_pr_number(c) }
    if pr_numbers.empty?
      warning "Found #{commits.length} stacked commits but no PRs for any of them"
      next
    end
    results = pr_numbers.map { |n| [n, train("pr", "assign", Git.repo_name_with_org, n, *expanded)] }
    report_train_results(results, "Assigned #{expanded.inspect} to")
  end

  desc "Mark every PR in the current stack as QA-bound so the train holds it until QA Passed"
  task bind_qa: :before do |task, args|
    branch = Git.current_branch
    commits = Git.my_commits_between(base_stacking_branch, branch, "austin")
    if commits.empty?
      warning "No stacked commits between #{base_stacking_branch} and #{branch}; nothing to bind"
      next
    end
    pr_numbers = commits.filter_map { |c| get_stacked_pr_number(c) }
    if pr_numbers.empty?
      warning "Found #{commits.length} stacked commits but no PRs for any of them"
      next
    end
    results = pr_numbers.map { |n| [n, train("pr", "bind-qa", Git.repo_name_with_org, n)] }
    report_train_results(results, "QA-bound")
  end

  def create_stacked_prs(base, parent)
    source_branch = Git.current_branch
    info "Creating stacked PRs for #{base}..#{source_branch}"
    commits = Git.my_commits_between(base, source_branch, "austin")
    if commits.empty?
      warning "No stacked commits between #{base} and #{source_branch}"
      return
    end

    plan = commits.map { |commit| plan_stacked_entry(commit) }
    ordering_findings = downstream_fix_findings(plan)
    report_stack_ordering(ordering_findings)

    system "git", "fetch", "-q", "origin", base
    info "Pushing #{plan.length} stacked branch(es)"
    prev_branch = base
    prev_sha = nil
    expected_bases = {}
    plan.each_with_index do |entry, index|
      if already_in_base?(entry[:commit], base)
        warning "#{entry[:commit][0, 10]} is already in #{base}; skipping #{entry[:branch]}"
        next
      end
      remote = matching_remote_sha(entry[:branch], entry[:commit], prev_sha)
      if remote
        info "#{entry[:branch]} already carries #{entry[:commit][0, 10]}; skipping push"
      else
        error "Failed to push #{entry[:branch]}" unless GitHub.push_sha(entry[:commit], entry[:branch])
      end
      pr_number = sync_stacked_pr(entry, prev_branch)
      prev_sha = remote || entry[:commit]
      if pr_number.nil?
        warning "No PR for #{entry[:branch]} — skipping train registration"
        prev_branch = entry[:branch]
        next
      end
      expected_bases[pr_number] = prev_branch
      prev_branch = entry[:branch]
      # Only position it if it actually went in — moving a PR that is not in the train is a
      # refusal we would then report as a successful reorder.
      if train("pr", "add", parent, Git.repo_name_with_org, pr_number)
        train("train", "move", parent, Git.repo_name_with_org, pr_number, index)
      end
    end

    unless expected_bases.empty?
      states = GitHub.pull_request_states(Git.repo_name_with_org, expected_bases.keys)
      reconcile_stacked_bases(expected_bases, states)
      link_stack(base, expected_bases.keys, states) if expected_bases.length > 1
    end

    unless ordering_findings.empty?
      warning "Stack ordering: #{ordering_findings.map { |f| f[:entry][:commit][0, 10] }.join(", ")} still sit above the commit(s) they look like a fix for — detail at the top of this run"
    end
  end

  # A merged PR still counts as a member, so growing an existing stack goes by its number — listing
  # only the open PRs reads as "remove the merged one" and is refused.
  def link_stack(base, pr_numbers, states)
    stack = pr_numbers.filter_map { |n| states[n]&.dig("stack", "number") }.first
    target = stack ? ["stack ##{stack}", [stack.to_s]] : ["a GitHub stack on #{base}", ["--base", base]]
    info "Linking ##{pr_numbers.join(", #")} into #{target[0]}"
    return if system("gh", "stack", "link", *target[1], *pr_numbers.map(&:to_s))
    warning "gh stack link failed; the PRs are chained by base branch but carry no stack map"
  end

  def get_first_stacked_pr_number(base)
    first_commit = get_first_commit(base)
    return nil if first_commit.nil?
    get_stacked_pr_number(first_commit)
  end

  def get_stacked_pr_number(commit)
    GitHub.open_pr_number(plan_stacked_entry(commit)[:branch])
  end

  def get_first_commit(base)
    commits = Git.my_commits_between(base, Git.current_branch, "austin")
    commits.empty? ? nil : commits.first
  end

  desc "Run ./gradlew classes on all commits in the current branch"
  task build: :before do |task, args|
    branches = get_branches(args)
    branches.each do |branch|
      Git.ensure_clean
      system "git", "checkout", branch
      Git.ensure_clean
      cmd = "./gradlew classes"
      # check for microservices directory
      if Dir.exist?("microservices")
        cmd = "./gradlew -p microservices classes && ./gradlew :data-interface:classes"
      end
      error "Test failed for #{branch}" unless system "git", "rebase", "-x", cmd, base_stacking_branch
    end
  end

  def stacking_source_branches
    Git.find_branches('^austin/[su]/.*$')
  end

  def stacking_base_for(branch)
    branch.start_with?("austin/u/") ? "production" : base_stacking_branch
  end

  def expected_stacked_branch(commit)
    subject = Git.commit_message(commit)[:title].to_s.strip
    first_token = subject.split(/\s+/, 2)[0].to_s
    first_token.empty? ? nil : "stacks/austin/#{first_token}"
  end

  def expected_stacked_branches
    stacking_source_branches.each_with_object([]) do |branch, acc|
      commits = Git.my_commits_between(stacking_base_for(branch), branch, "austin")
      acc.concat(commits.filter_map { |commit| expected_stacked_branch(commit) })
    end.uniq
  end

  def orphaned_stacked_branches
    remote_stacked_branches - expected_stacked_branches
  end

  desc "Report pushed stacks/austin/* branches that no longer back a source commit"
  task orphaned: :before do |task, args|
    expected = expected_stacked_branches
    remote = remote_stacked_branches
    (remote - expected).each do |branch|
      pr = GitHub.open_pr_number(branch)
      warning "Orphaned stack branch #{branch}#{pr ? " (PR ##{pr})" : " (no open PR)"}"
    end
    (remote & expected).each do |branch|
      pr = GitHub.open_pr_number(branch)
      info "#{pr ? "PR ##{pr}" : "no open PR"} → #{branch}"
    end
    info "No orphaned stack branches found" if (remote - expected).empty?
  end

  desc "Delete pushed stacks/austin/* branches that no longer back a source commit (closing their PRs) and drop them from the train"
  task prune: :before do |task, args|
    orphaned = orphaned_stacked_branches
    if orphaned.empty?
      info "No orphaned stack branches found"
      next
    end
    prs_by_branch = orphaned.to_h { |branch| [branch, GitHub.open_pr_number(branch)] }
    warning "Found #{orphaned.length} orphaned stack branch(es):"
    orphaned.each do |branch|
      pr = prs_by_branch[branch]
      warning "  #{branch}#{pr ? " (PR ##{pr})" : ""}"
    end
    info "Delete these branches on origin (closing their PRs)? (y/n)"
    unless STDIN.gets.to_s.strip.downcase.start_with?("y")
      info "Aborted; nothing deleted"
      next
    end
    orphaned.each { |branch| system "git", "push", "origin", "--delete", branch }
    pr_numbers = prs_by_branch.values.compact
    unless pr_numbers.empty?
      results = pr_numbers.map { |n| [n, train("pr", "remove", Git.repo_name_with_org, n)] }
      report_train_results(results, "Removed from the train")
    end
  end
end
