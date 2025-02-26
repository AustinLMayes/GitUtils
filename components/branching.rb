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
    if to_branch($dev_branch)
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
      return system "git", "merge", current, "--no-edit"
    when :rebase
      info "Rebasing #{current} onto #{target}"
      return system "git", "rebase", current
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

  desc "Make multiple branches out of the unpushed commits"
  task new_cherry_all: :before do |task, args|
    branches = {
      # "branch-name" => [%w(commit1 commit2), "PR Title", "Jira comment (optional)", false to not merge to master],
      "expire-fix" => [%w(985b95a), "CC-9263 Fix Rank Expiration Menu"],
      "bw-fixes" => [%w(4d9bbf3 b9c8051), "BlockWars Fixes"],
      "offline-fixes" => [%w(8f3e757 d07b452 fa3cc32 63b82c4 eaea7b6 62ee79b 20556c7), "Fix Many Exceptions Caused By Players Leaving"],
      "cmd-fixes" => [%w(fabffb7 df22551), "Fix Some Command System Issues"],
      "ffa-fixes" => [%w(048d296 e0170f2 461d386 d7d24c2), "FFA Fixes"],
      "ac-fix" => [%w(adde725 0b50a90), "Sentinel Fix"],
      "misc-fixes" => [%w(d00e9eb ee1cdcc 338dee3 1f1e830), "Miscellaneous Fixes"],
    }
    by_branch = {}
    unknown = []
    Git.commits_after(Time.now - 2.days).each do |commit|
      message = `git log --format=%B -n 1 #{commit}`.strip.split("\n").first
      author = `git log --format=%an -n 1 #{commit}`.strip
      next unless author.include? "Austin"
      commit_short = commit[0..6]
      found = false
      branches.each do |branch, data|
        if data[0].include? commit_short
          by_branch[branch] ||= []
          by_branch[branch] << commit
          found = true
          break
        end
      end
      unknown << [commit_short, message] unless found
    end

    if unknown.length > 0
      error "Unknown commits: #{unknown.map { |x| x[0] + " - " + x[1] }.join("\n")}"
    end

    first_current = Git.current_branch
    # pull_base
    prs = []
    by_branch.each do |branch, commits|
      data = branches[branch]
      if Git.branch_exists "austin/#{branch}"
        warn "Branch austin/#{branch} already exists!"
        sleep 3
      end
      system "git", "stash"
      system "git", "checkout", "production"
      @current = "production"
      make_branch branch, "production"
      @current = Git.current_branch
      did_any = false
      commits.each do |commit|
        message = `git log --format=%B -n 1 #{commit}`.strip.split("\n").first
        # Skip of commit message is already in the branch
        if `git log -n 25 --format=%B`.include? message
          warn "Commit #{commit} already in branch #{branch}"
          next
        end
        did_any = true
        time = `git log --format=%ct -n 1 #{commit}`.strip
        system "GIT_COMMITTER_DATE=\"#{time}\" git cherry-pick --allow-empty #{commit}"
      end
      info "Cherry picked #{commits.length} commits to #{branch}"
      if did_any
        merge_master = data.length > 3 ? data[3] : true
        wait_range 5, 10
        if merge_master
          if to_branch($dev_branch)
            system "git", "checkout", @current
          else
            error "merge failed"
          end
          wait_range 5, 10
          push_all $dev_branch
        end
        push_all @current
        wait_range 5, 10
        prs << make_prs(data[1], false)
      end
      commits.each do |commit|
        transition_issues(commit, data[2])
      end
    end
    info "@here #{prs.join("\n")}"
    system "git", "checkout", first_current
  end

  desc "Rebase the current branch onto production"
  task rebase_prod: :before do |task, args|
    dont_pull = args.extras[0] == "false"
    branches = [Git.current_branch]
    if dont_pull
      args.extras.shift
    end
    if args.extras.length > 1
      branches = Git.find_branches_multi(args.extras)
    end
    branches.delete("austin/stage")
    system "git", "stash"
    pull_base unless dont_pull
    branches.each do |branch|
      system "git", "checkout", "production"
      if to_branch(branch, strategy: :rebase)
        system "git", "checkout", branch
        if to_branch($dev_branch)
          system "git", "checkout", branch
        else
          error "merge failed"
        end
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
    branches = [Git.current_branch]
    if args.extras.length > 0
      branches = Git.find_branches_multi(args.extras)
    end
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
end
