require 'active_support/time'

namespace :br do
  desc "Pull all of the selected branches"
  task pull_all: :before do |task, args|
    Git.pull_branches *args.extras, ensure_exists: true
    Git.stream nil, "checkout", @current
  end

  desc "Reset repos to the latest commit from remote"
  task :reset do |task, args|
    dirs = FileUtils.parse_args(args, 0)
    dirs.each do |dir|
      Dir.chdir(dir) do
        Git.stream nil, "fetch", "--all"
        Git.stream nil, "add", "."
        Git.stream nil, "reset", "--hard", "origin/#{Git.current_branch}"
      end
    end
  end

  desc "Run a command on the selected Git branches"
  task act_on_all: :before do |task, args|
    command = args.extras[0]
    act_on_all(command, *args.extras.drop(1))
  end

  desc "Run a command on the base branches"
  task act_on_base: :before do |task, args|
    command = args.extras[0]
    act_on_all(command, *Git.base_branches)
  end

  def act_on_all(command, *branches)
    Git.act_on_branches *branches, ensure_exists: true, delay: [0, 0] do |branch|
      info "Executing #{command} on #{branch}"
      system command
    end
    Git.stream nil, "checkout", @current
  end

  desc "Push all of the selected branches"
  task push_all: :before do |task, args|
    push_all *get_non_stacked_branches(args), $dev_branch
  end

  def push_all(*branches, force: false)
    return if $dont_push
    delay = $delays_enabled ? [5, 25] : [0, 0]
    branches = branches.shuffle
    # never push production
    branches.delete("production")
    Git.push_branches *branches, ensure_exists: false, delay: delay, force: force
    Git.stream nil, "checkout", @current
  end

  desc "Force push the selected austin/* branches"
  task force_push_all: :before do |task, args|
    branches = get_non_stacked_branches(args)
    # Hard guard, not a filter of convenience: only the `all` selector is
    # constrained to austin/*, while an explicit pattern resolves to whatever it
    # matches and no args at all falls back to the current branch, which may well
    # be production or master. Force pushing is only ever safe on my own
    # branches, so drop everything else and say what was dropped. The start
    # anchor is also what keeps the stacks/austin/* PR heads out.
    skipped = branches.reject { |branch| branch.start_with?("austin/") }
    warning "Refusing to force push #{skipped.join(", ")}" unless skipped.empty?
    push_all *(branches - skipped), force: true
  end

  desc "Pull all of the base branches"
  task pull_base: :before do |task, args|
    Git.stream nil, "stash"
    pull_base
    Git.stream nil, "checkout", @current
    Git.stream nil, "stash", "pop"
  end

  def pull_base
    Git.pull_branches *Git.base_branches, ensure_exists: false
  end

  desc "Merge the current branch to master"
  task to_master: :before do |task, args|
    strategy = args.extras.length > 0 ? args.extras[0].to_sym : :merge
    if to_branch($dev_branch, strategy: strategy)
      Git.stream nil, "checkout", @current
    else
      error "merge failed"
    end
  end

  desc "Merge the current branch to staging"
  task to_staging: :before do |task, args|
    if to_branch("staging")
      Git.stream nil, "checkout", @current
    else
      error "merge failed"
    end
  end

  def to_branch(target, strategy: :merge)
    current = Git.current_branch
    Git.stream nil, "checkout", target
    Git.ensure_branch target
    case strategy
    when :merge
      info "Merging #{current} into #{target}"
      return Git.stream nil, "merge", current, "--no-edit", "--rerere-autoupdate"
    when :tmerge
      info "Merging #{current} into #{target} using theirs strategy"
      return Git.stream nil, "merge", current, "--no-edit", "-X", "theirs", "--rerere-autoupdate"
    when :smerge
      info "Squash merging #{current} into #{target}"
      res = Git.stream nil, "merge", "--squash", current
      if res
        Git.stream nil, "commit", "--no-edit", "-m", "Merge branch '#{current}' into #{target}"
        return true
      else
        return false
      end
    when :rebase
      info "Rebasing #{current} onto #{target}"
      return Git.stream nil, "rebase", current
    when :cherry
      info "Cherry-picking #{current} onto #{target}"
      commits = Git.commits_between(target, current)
      return Git.stream nil, "cherry-pick", "--allow-empty", *commits
    else
      raise "Unknown strategy #{strategy}"
    end
  end

  def rebase_onto(base, from, to)
    Git.stream nil, "checkout", base
    Git.stream nil, "pull"
    Git.stream nil, "checkout", @current
    if base.nil?
      Git.stream nil, "rebase", from, to
      return
    end
    Git.stream nil, "rebase", "--onto", base, from, to
  end

  desc "Rebase the current branch onto the specified branch"
  task rebase: :before do |task, args|
    from = args.extras[0]
    to = args.extras[1] || @current
    to = @current if to == "c"
    base = args.extras[2] || "production"
    rebase_onto(base, from, to)
  end

  desc "Push master and curbranch"
  task push_up: :before do |task, args|
    info "Pusing all branches to remote"
    push_all $dev_branch, @current
  end

  desc "Make a new branch based off of production"
  task new: :before do |task, args|
    Git.stream nil, "stash"
    make_branch args.extras[0], "production"
    Git.stream nil, "stash", "pop"
  end

  def make_branch(name, base)
    Git.stream nil, "checkout", base
    Git.ensure_branch base
    name = "austin/" + name
    info "Creating #{name} based off of #{base}"
    Git.stream nil, "go", name
  end

  desc "Make a branch and cherry-pick the specified commits"
  task new_cherry: :before do |task, args|
    Git.stream nil, "stash"
    make_branch args.extras[0], "production"
    Git.stream nil, "cherry-pick", *args.extras.drop(1)
    Git.stream nil, "stash", "pop"
  end

  desc "Rebase the current branch onto production"
  task rebase_prod: :before do |task, args|
    dont_pull = args.extras[0] == "false"
    branches = [Git.current_branch]
    if dont_pull
      args.extras.shift
    end
    if args.extras.length > 0
      branches = Git.find_branches_multi(args.extras)
    end
    branches.delete("austin/stage")
    Git.stream nil, "stash"
    pull_base unless dont_pull
    branches.each do |branch|
      Git.stream nil, "checkout", "production"
      if to_branch(branch, strategy: :rebase)
        Git.stream nil, "checkout", branch
      else
        error "rebase failed"
      end
    end
    Git.stream nil, "checkout", @current
    push_all *branches, $dev_branch, force: true
    Git.stream nil, "stash", "pop"
  end

  desc "Merge production into the current branch"
  task merge_prod: :before do |task, args|
    dont_pull = args.extras[0] == "false"
    branches = [Git.current_branch]
    if dont_pull
      args.extras.shift
    end
    if args.extras.length > 0
      branches = Git.find_branches_multi(args.extras)
    end
    pull_base unless dont_pull
    branches.each do |branch|
      Git.stream nil, "stash"
      Git.stream nil, "checkout", "production"
      if to_branch(branch)
        Git.stream nil, "checkout", branch
      else
        error "merge failed"
      end
      Git.stream nil, "stash", "pop"
    end
    push_all *branches, $dev_branch
  end

  desc "Delete and re-pull the master branch"
  task reset_master: :before do |task, args|
    Git.stream nil, "stash"
    Git.stream nil, "checkout", "production"
    Git.stream nil, "branch", "-D", $dev_branch
    Git.stream nil, "fetch", "origin", $dev_branch + ":" + $dev_branch
    Git.stream nil, "checkout", @current
    Git.stream nil, "stash", "pop"
  end

  desc "Merge production into main branch"
  task sync_master: :before do |task, args|
    Git.stream nil, "stash"
    Git.stream nil, "checkout", "production"
    Git.stream nil, "pull"
    Git.stream nil, "checkout", $dev_branch
    Git.stream nil, "pull"
    Git.stream nil, "merge", "--no-edit", "production"
    Git.push
    Git.stream nil, "checkout", @current
    Git.stream nil, "stash", "pop"
  end

  desc "Request review for the PR"
  task to_testing: :before do |task, args|
    branches = get_non_stacked_branches(args)
    nums = []
    branches.each do |branch|
      pr_number = GitHub.get_pr_number(branch)
      if pr_number.nil?
        warning "No PR found for the current branch #{branch}, skipping"
        next
      end
      nums << pr_number
    end
    if nums.empty?
      warning "No PRs found for any of the branches, skipping"
    else
      results = nums.map { |num| [num, train("pr", "to-testing", Git.repo_name_with_org, num)] }
      report_train_results(results, "Queued for dev")
    end
  end

  desc "Resolve all open review conversations on the PR"
  task resolve: :before do |task, args|
    branches = get_non_stacked_branches(args)
    nums = []
    branches.each do |branch|
      pr_number = GitHub.get_pr_number(branch)
      if pr_number.nil?
        warning "No PR found for the current branch #{branch}, skipping"
        next
      end
      nums << pr_number
    end
    if nums.empty?
      warning "No PRs found for any of the branches, skipping"
    else
      results = nums.map { |num| [num, train("pr", "resolve", Git.repo_name_with_org, num)] }
      report_train_results(results, "Resolved conversations on")
    end
  end
end
