require 'common'
require 'active_support/time'

namespace :br do
  desc "Pull all of the selected branches"
  task pull_all: :before do |task, args|
    Git.pull_branches *args.extras, ensure_exists: true
    system "git", "checkout", @current
  end

  desc "Reset repos to the latest commit from remote"
  task :reset do |task, args|
    dirs = FileUtils.parse_args(args, 0)
    dirs.each do |dir|
      Dir.chdir(dir) do
        system "git", "fetch", "--all"
        system "git", "add", "."
        system "git", "reset", "--hard", "origin/#{Git.current_branch}"
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
    act_on_all(command, *base_branches)
  end

  def act_on_all(command, *branches)
    Git.act_on_branches *branches, ensure_exists: true, delay: [0, 0] do |branch|
      info "Executing #{command} on #{branch}"
      system command
    end
    system "git", "checkout", @current
  end

  desc "Push all of the selected branches"
  task push_all: :before do |task, args|
    push_all *args.extras
  end

  def push_all(*branches, force: false)
    return if $dont_push
    delay = $delays_enabled ? [5, 25] : [0, 0]
    branches = branches.shuffle
    # never push production
    branches.delete("production")
    Git.push_branches *branches, ensure_exists: false, delay: delay, force: force
    system "git", "checkout", @current
  end

  desc "Pull all of the base branches"
  task pull_base: :before do |task, args|
    system "git", "stash"
    pull_base
    system "git", "checkout", @current
    system "git", "stash", "pop"
  end

  def pull_base
    Git.pull_branches *base_branches, ensure_exists: false
  end

  desc "Merge the current branch to master"
  task to_master: :before do |task, args|
    strategy = args.extras.length > 0 ? args.extras[0].to_sym : :merge
    if to_branch($dev_branch, strategy: strategy)
      system "git", "checkout", @current
    else
      error "merge failed"
    end
  end

  desc "Merge the current branch to staging"
  task to_staging: :before do |task, args|
    if to_branch("staging")
      system "git", "checkout", @current
    else
      error "merge failed"
    end
  end

  def to_branch(target, strategy: :merge)
    current = Git.current_branch
    system "git", "checkout", target
    Git.ensure_branch target
    case strategy
    when :merge
      info "Merging #{current} into #{target}"
      return system "git", "merge", current, "--no-edit", "--rerere-autoupdate"
    when :tmerge
      info "Merging #{current} into #{target} using theirs strategy"
      return system "git", "merge", current, "--no-edit", "-X", "theirs", "--rerere-autoupdate"
    when :smerge
      info "Squash merging #{current} into #{target}"
      res = system "git", "merge", "--squash", current
      if res
        system "git", "commit", "--no-edit", "-m", "Merge branch '#{current}' into #{target}"
        return true
      else
        return false
      end
    when :rebase
      info "Rebasing #{current} onto #{target}"
      return system "git", "rebase", current
    when :cherry
      info "Cherry-picking #{current} onto #{target}"
      commits = Git.commits_between(target, current).join(" ")
      return system "git cherry-pick --allow-empty #{commits}"
    else
      raise "Unknown strategy #{strategy}"
    end
  end

  def rebase_onto(base, from, to)
    system "git", "checkout", base
    system "git", "pull"
    system "git", "checkout", @current
    if base.nil?
      system "git", "rebase", from, to
      return
    end
    system "git", "rebase", "--onto", base, from, to
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
    system "git", "stash"
    make_branch args.extras[0], "production"
    system "git", "stash", "pop"
  end

  def make_branch(name, base)
    system "git", "checkout", base
    Git.ensure_branch base
    name = "austin/" + name
    info "Creating #{name} based off of #{base}"
    system "git", "go", name
  end

  desc "Make a branch and cherry-pick the specified commits"
  task new_cherry: :before do |task, args|
    system "git", "stash"
    make_branch args.extras[0], "production"
    system "git", "cherry-pick", *args.extras.drop(1)
    system "git", "stash", "pop"
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
    system "git", "stash"
    pull_base unless dont_pull
    branches.each do |branch|
      system "git", "checkout", "production"
      if to_branch(branch, strategy: :rebase)
        system "git", "checkout", branch
      else
        error "rebase failed"
      end
    end
    system "git", "checkout", @current
    push_all *branches, $dev_branch, force: true
    system "git", "stash", "pop"
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
      system "git", "stash"
      system "git", "checkout", "production"
      if to_branch(branch)
        system "git", "checkout", branch
        if to_branch($dev_branch)
          system "git", "checkout", branch
        else
          error "merge failed"
        end
      else
        error "merge failed"
      end
      system "git", "stash", "pop"
    end
    push_all *branches, $dev_branch
  end

  desc "Delete and re-pull the master branch"
  task reset_master: :before do |task, args|
    system "git", "stash"
    system "git", "checkout", "production"
    system "git", "branch", "-D", $dev_branch
    system "git", "fetch", "origin", $dev_branch + ":" + $dev_branch
    system "git", "checkout", @current
    system "git", "stash", "pop"
  end

  desc "Merge production into main branch"
  task sync_master: :before do |task, args|
    system "git", "stash"
    system "git", "checkout", "production"
    system "git", "pull"
    system "git", "checkout", $dev_branch
    system "git", "pull"
    system "git", "merge", "--no-edit", "production"
    system "git", "push"
    system "git", "checkout", @current
    system "git", "stash", "pop"
  end
end
