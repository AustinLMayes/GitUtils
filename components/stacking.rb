# Source-commit -> { commit:, branch:, message: }. First whitespace-token of
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
  message = body.strip.empty? ? rest : "#{rest}\n\n#{body}"
  { commit: commit, branch: branch, message: message, title: rest, description: body.strip,
    subject: subject, label: first_token }
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

# Skip-condition for the cherry-pick + amend rebuild on subsequent runs.
def stacked_branch_up_to_date?(branch, source_commit, expected_message, parent_branch)
  return false unless Git.branch_exists(branch)
  branch_tree = `git rev-parse #{branch}^{tree} 2>/dev/null`.strip
  source_tree = `git rev-parse #{source_commit}^{tree} 2>/dev/null`.strip
  return false if branch_tree.empty? || branch_tree != source_tree
  parent_tip = `git rev-parse #{parent_branch} 2>/dev/null`.strip
  branch_parent_tip = `git rev-parse #{branch}^ 2>/dev/null`.strip
  return false if parent_tip.empty? || parent_tip != branch_parent_tip
  branch_message = `git log -1 --pretty=%B #{branch}`.strip
  branch_message == expected_message.strip
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
    system "git checkout #{base_stacking_branch}"
    system "git pull"
    branches.each do |branch|
      system "git", "checkout", branch
      Git.ensure_clean
      create_stacked_prs(base_stacking_branch, branch)
      system "git", "checkout", branch
      Git.push(force: true)
    end
    system "git checkout #{current}"
  end

  desc "Request review for the first stacked PR"
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

    # gt's stack diff is computed against this base, so fetch it fresh.
    system "git", "fetch", "origin", base

    info "Materializing #{plan.length} stacked branch(es) and tracking them in Graphite"
    prev_branch = base
    plan.each do |entry|
      if stacked_branch_up_to_date?(entry[:branch], entry[:commit], entry[:message], prev_branch)
        info "#{entry[:branch]} already matches source commit on top of #{prev_branch}; skipping rebuild"
        system "git", "checkout", entry[:branch]
      else
        system "git", "branch", "-D", entry[:branch], out: File::NULL, err: File::NULL if Git.branch_exists(entry[:branch])
        error "Failed to create #{entry[:branch]}" unless system("git", "checkout", "-b", entry[:branch], prev_branch)
        unless system("git", "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", entry[:commit])
          system "git", "cherry-pick", "--abort"
          error "Cherry-pick failed for #{entry[:commit]} → #{entry[:branch]}"
        end
        error "Failed to amend commit message for #{entry[:branch]}" unless system("git", "commit", "--amend", "-m", entry[:message])
      end
      system("gt", "track", "--parent", prev_branch, "--no-interactive", out: File::NULL, err: File::NULL)
      prev_branch = entry[:branch]
    end

    # --force overrides graphite's "remote SHA changed under you" guard —
    # safe here because we own these sub-branches and the local rebuild is
    # always the source of truth.
    info "Submitting stack via Graphite"
    begin
      Graphite.submit(stack: true, force: true)
    rescue Graphite::Error => e
      system "git", "checkout", source_branch
      error "gt submit --stack failed: #{e.message}"
    end

    system "git", "checkout", source_branch

    pr_numbers_by_branch = Graphite.local_pr_numbers
    plan.each_with_index do |entry, index|
      pr_number = pr_numbers_by_branch[entry[:branch]]
      if pr_number.nil?
        warning "No PR number found for #{entry[:branch]} in .graphite_pr_info — skipping train registration"
        next
      end
      # WORKAROUND: `gt submit` only sets the PR title/description on creation,
      # so an edited commit subject/body (e.g. a reworded title or an added
      # `Depends on …` trailer) never reaches an existing PR. Force both to
      # match the source commit — title is the first-token-stripped subject,
      # body is the commit body.
      unless system("gh", "pr", "edit", pr_number.to_s, "--repo", Git.repo_name_with_org,
                    "--title", entry[:title], "--body", entry[:description], out: File::NULL, err: File::NULL)
        warning "Failed to sync PR ##{pr_number} title/description via gh pr edit"
      end
      # Only position it if it actually went in — moving a PR that is not in the train is a
      # refusal we would then report as a successful reorder.
      if train("pr", "add", parent, Git.repo_name_with_org, pr_number)
        train("train", "move", parent, Git.repo_name_with_org, pr_number, index)
      end
    end

    # Re-stated here because the detail above is printed before `gt submit`, whose output buries it.
    unless ordering_findings.empty?
      warning "Stack ordering: #{ordering_findings.map { |f| f[:entry][:commit][0, 10] }.join(", ")} still sit above the commit(s) they look like a fix for — detail at the top of this run"
    end
  end

  def get_first_stacked_pr_number(base)
    first_commit = get_first_commit(base)
    return nil if first_commit.nil?
    get_stacked_pr_number(first_commit)
  end

  def get_stacked_pr_number(commit)
    Graphite.local_pr_numbers[plan_stacked_entry(commit)[:branch]]
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
    current = Git.current_branch
    expected = stacking_source_branches.each_with_object([]) do |branch, acc|
      next unless Git.branch_exists(branch)
      system "git", "checkout", branch
      Git.ensure_clean
      commits = Git.my_commits_between(stacking_base_for(branch), branch, "austin")
      acc.concat(commits.filter_map { |commit| expected_stacked_branch(commit) })
    end.uniq
    system "git", "checkout", current if Git.branch_exists(current)
    expected
  end

  def orphaned_stacked_branches
    Git.find_branches('^stacks/austin/.*$') - expected_stacked_branches
  end

  desc "Report stacks/austin/* branches and PRs that no longer back a source commit"
  task orphaned: :before do |task, args|
    expected = expected_stacked_branches
    prs_by_branch = Graphite.local_pr_numbers
    local = Git.find_branches('^stacks/austin/.*$')
    orphaned_prs = prs_by_branch.keys - expected
    orphaned_local = local - expected - orphaned_prs
    found = prs_by_branch.keys & expected
    orphaned_prs.each { |branch| warning "Orphaned PR ##{prs_by_branch[branch]} for branch #{branch}" }
    orphaned_local.each { |branch| warning "Orphaned local stack branch #{branch} (no tracked PR)" }
    found.each { |branch| info "PR ##{prs_by_branch[branch]} → #{branch}" }
    info "No orphaned stack branches or PRs found" if orphaned_prs.empty? && orphaned_local.empty?
  end

  desc "Delete local stacks/austin/* branches that no longer back a source commit. Pass `remote` to also delete the pushed branch (closing its PR) and drop it from the train."
  task prune: :before do |task, args|
    current = Git.current_branch
    Git.ensure_clean
    also_remote = args.extras.include?("remote")
    orphaned = orphaned_stacked_branches
    if orphaned.empty?
      info "No orphaned stack branches found"
      next
    end
    prs_by_branch = Graphite.local_pr_numbers
    warning "Found #{orphaned.length} orphaned stack branch(es):"
    orphaned.each do |branch|
      pr = prs_by_branch[branch]
      warning "  #{branch}#{pr ? " (PR ##{pr})" : ""}"
    end
    info "Delete #{also_remote ? "these branches remotely (closing their PRs) and locally" : "these local branches (pass `remote` to also close PRs)"}? (y/n)"
    unless STDIN.gets.to_s.strip.downcase.start_with?("y")
      info "Aborted; nothing deleted"
      next
    end
    system "git", "checkout", base_stacking_branch
    Git.delete_branches(*orphaned, remote: also_remote)
    if also_remote
      pr_numbers = orphaned.filter_map { |branch| prs_by_branch[branch] }
      unless pr_numbers.empty?
        results = pr_numbers.map { |n| [n, train("pr", "remove", Git.repo_name_with_org, n)] }
        report_train_results(results, "Removed from the train")
      end
    end
    system "git", "checkout", (Git.branch_exists(current) ? current : base_stacking_branch)
  end
end
