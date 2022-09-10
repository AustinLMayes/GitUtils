require_relative 'common'

desc "Wait between x and x seconds"
task :wait do |task, args|
  wait_range *args.extras
end

desc "Run prereqs"
task :before do |task, args|
  Git.ensure_git Dir.pwd
  @current = Git.current_branch
  unless ENV["GUTILS_DO_DELAY"]
    info "Delay variable not set! Use delays (y/n)"
    input = STDIN.gets.strip.downcase
    input = "y" unless input
  end
  $delays_enabled = ENV["GUTILS_DO_DELAY"] == "true"
  info ($delays_enabled ? "" : "NOT ") + "Using Delays!"
  $extra_slow = ENV["GUTILS_EXTRA_SLOW"] == "true"
  info "Using double delay times" if $extra_slow
  $gamedev = ENV["GAME_FRAMEWORK"] == "true"
end

desc "Pull all of the selected branches"
task pull_all: :before do |task, args|
  Git.pull_branches *args.extras, ensure_exists: true
  system "git", "checkout", @current
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
  Git.act_on_branches *branches, ensure_exists: true, delay: [0,0] do |branch|
    info "Executing #{command} on #{branch}"
    system command
  end
  system "git", "checkout", @current
end

desc "Push all of the selected branches"
task push_all: :before do |task, args|
  push_all *args.extras
end

def push_all(*branches)
  delay = $delays_enabled ? [5, 25] : [0,0]
  branches = branches.shuffle
  Git.push_branches *branches, ensure_exists: false, delay: delay
  system "git", "checkout", @current
end

desc "Pull all of the base branches"
task pull_base: :before do |task, args|
  pull_base
  system "git", "checkout", @current
end

def pull_base
  Git.pull_branches *base_branches, ensure_exists: false
end

desc "Make an MCO version of the current branch"
task make_mco: :before do |task, args|
  mco_name = @current + "-mco"
  info "Making branch named #{mco_name}"
  system "git", "checkout", "production-gameframework-mco"
  Git.ensure_branch "production-gameframework-mco"
  system "git", "checkout", "-b", mco_name
  Git.ensure_branch mco_name
  info "Created branch named #{mco_name}"
  system "git", "checkout", @current
end

desc "Merge the current branch to MCO"
task merge_mco: :before do |task, args|
  if merge_mco
    system "git", "checkout", @current
  else
    error "merge failed"
  end
end

def merge_mco
  error "You can only run this on non-mco branches!" if @current.end_with? "mco"
  mco_name = @current + "-mco"
  Git.ensure_exists mco_name
  system "git", "go", mco_name
  Git.ensure_branch mco_name
  info "Merging commits from #{@current} to #{mco_name}"
  return system "git", "merge", @current, "--no-edit"
end

desc "Cherry pick the last branch into MCO"
task cherry_mco: :before do |task, args|
  if cherry_mco
    system "git", "checkout", @current
  else
    error "cherry-pick failed"
  end
end

def cherry_mco
  error "You can only run this on non-mco branches!" if @current.end_with? "mco"
  mco_name = @current + "-mco"
  Git.ensure_exists mco_name
  commit = `git rev-parse --short HEAD`.strip
  system "git", "go", mco_name
  Git.ensure_branch mco_name
  info "Cherry-picking #{commit} from #{@current} to #{mco_name}"
  return system "git", "cherry-pick", commit, "--no-edit"
end

desc "Merge the current branch to gamedevnet"
task to_gamedev: :before do |task, args|
  if to_gamedev
    system "git", "checkout", @current
  else
    error "merge failed"
  end
end

desc "Merge the current branch to master-gameframework"
task to_master: :before do |task, args|
  if to_master
    system "git", "checkout", @current
  else
    error "merge failed"
  end
end

def to_gamedev
  current  = Git.current_branch
  target = current.end_with?("mco") ? "gamedevnet-mco" : "gamedevnet"
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

def to_master
  current  = Git.current_branch
  target = current.end_with?("mco") ? "master-gameframework-mco" : "master-gameframework"
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

desc "Deploy the @urrent branch to master-gameframework, merge into MCO, and deploy that to master-gameframework-mco"
task deploy_merge: :before do |task, args|
  deploy "Merge" do
    merge_mco
  end
end

desc "Deploy the current branch to master-gameframework, cherry-pick into MCO, and deploy that to master-gameframework-mco"
task deploy_cherry: :before do |task, args|
  deploy "Cherry-Pick" do
    cherry_mco
  end
end

def deploy(verb, &block)
  mco = @current.end_with? "mco"
  warning "Running on MCO branch! Skipping java merge!" if mco
  mco_name = mco ? @current : @current + "-mco"
  base_name = mco ? @current[0..-5] : @current
  Git.ensure_exists mco_name
  Git.ensure_exists base_name
  unless mco
    if to_gamedev
      info "Merged #{base_name} to gamedevnet"
      system "git", "checkout", base_name
      wait_range 5, 20 if $delays_enabled
      if to_master
        info "Merged #{base_name} to master-gameframework"
        system "git", "checkout", base_name
        wait_range 5, 20 if $delays_enabled
        if block.call
          info "#{verb}ed #{base_name} to #{mco_name}"
          wait_range 10, 30 if $delays_enabled
        else
          error "#{verb} to MCO failed"
        end
      else
        error "Merge to master-gameframework failed"
      end
    else
      error "Merge to gamedev failed"
    end
  end

  system "git", "checkout", mco_name

  if to_gamedev
    info "Merged #{mco_name} to gamedevnet-mco"
    system "git", "checkout", mco_name
    wait_range 5, 25 if $delays_enabled
    if to_master
      info "Merged #{mco_name} to master-gameframework-mco"
      system "git", "checkout", base_name
      wait_range 5, 25 if $delays_enabled
      info "Pusing all branches to remote"
      push_all "master-gameframework", "master-gameframework-mco", "gamedevnet", "gamedevnet-mco", base_name, mco_name
      info "Pushed all branches to remote"
    else
      error "Merge to master-gameframework-mco failed"
    end
  else
    error "Merge to gamedevnet-mco failed"
  end
end

desc "Push master-gameframework,master-gameframework-mco,curbranch, and curbranch-mco"
task push_up: :before do |task, args|
  mco = @current.end_with? "mco"
  mco_name = mco ? @current : @current + "-mco"
  base_name = mco ? @current[0..-5] : @current

  info "Pusing all branches to remote"
  push_all "gamedevnet","gamedevnet-mco","master-gameframework", "master-gameframework-mco", base_name, mco_name
end

desc "Make a PR from the current branch"
task make_pr: :before do |task, args|
  make_prs(args.extras[0], false, (!args.extras[1].nil? && args.extras[1] == "true"))
end

desc "Make PRs from the current and MCO branches"
task make_prs: :before do |task, args|
  error "You can only run this on non-mco branches!" if @current.end_with? "mco"
  make_prs(args.extras[0], true, (!args.extras[1].nil? && args.extras[1] == "true"))
end

def make_prs(title, multi, slack)
  res = "@here "
  if multi
    Git.ensure_exists @current + "-mco"
    res << GitHub.make_pr(title, base: "production-gameframework", suffix: "[GFW]")
    wait_range 30, 60 if $delays_enabled
    system "git", "checkout", @current + "-mco"
    res << GitHub.make_pr(title, base: "production-gameframework-mco", suffix: "[GFW-MCO]")
  else
    base_branch = Git.current_branch.end_with?("mco") ? "production-gameframework-mco" : "production-gameframework"
    res << GitHub.make_pr(title, suffix: "[GFW]", base: base_branch)
  end

  system "git", "checkout", @current
  if slack
    Slack.send_message("#development-prs", res.gsub("\n", " "))
  else
    info res
  end
end

desc "Make a new branch based off of production"
task new: :before do |task, args|
  make_branch args.extras[0], "production-gameframework"
end

desc "Make a new branch based off of MCO"
task new_mco: :before do |task, args|
  make_branch args.extras[0] + "-mco", "production-gameframework-mco"
end

def make_branch(name, base)
  system "git", "checkout", base
  Git.ensure_branch base
  name = "austin/gameframework/" + name
  info "Creating #{name} based off of #{base}"
  system "git", "go", name
end
