require_relative 'common'
require "json"
require 'active_support/time'

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
  system "git", "checkout", "production-mco"
  Git.ensure_branch "production-mco"
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

def to_gamedev
  current  = Git.current_branch
  target = current.end_with?("mco") ? "gamedevnet-mco" : "gamedevnet"
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

desc "Merge the current branch to master"
task to_master: :before do |task, args|
  if to_master
    system "git", "checkout", @current
  else
    error "merge failed"
  end
end

def to_master
  current  = Git.current_branch
  target = current.end_with?("mco") ? "master-mco" : "master"
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

desc "Deploy the @urrent branch to master, merge into MCO, and deploy that to master-mco"
task deploy_merge: :before do |task, args|
  deploy "Merge" do
    merge_mco
  end
end

desc "Deploy the current branch to master, cherry-pick into MCO, and deploy that to master-mco"
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
    if to_master
      info "Merged #{base_name} to master"
      system "git", "checkout", base_name
      wait_range 5, 20 if $delays_enabled
      if block.call
        info "#{verb}ed #{base_name} to #{mco_name}"
        wait_range 10, 30 if $delays_enabled
      else
        error "#{verb} to MCO failed"
      end
    else
      error "Merge to master failed"
    end
  end

  system "git", "checkout", mco_name

  if to_master
    info "Merged #{mco_name} to master-mco"
    system "git", "checkout", base_name
    wait_range 5, 25 if $delays_enabled
    info "Pusing all branches to remote"
    push_all "master", "master-mco", base_name, mco_name
    info "Pushed all branches to remote"
  else
    error "Merge to master-mco failed"
  end
end

desc "Deploy Java and MCO to their respective GameDev branches"
task deploy_gamedev: :before do |task, args|
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
    else
      error "Merge to master failed"
    end
  end

  system "git", "checkout", mco_name

  if to_gamedev
    info "Merged #{mco_name} to gamedevnet-mco"
    system "git", "checkout", base_name
    wait_range 5, 25 if $delays_enabled
    info "Pusing all branches to remote"
    push_all "gamedevnet", "gamedevnet-mco", base_name, mco_name
    info "Pushed all branches to remote"
  else
    error "Merge to gamedevnet-mco failed"
  end
end

desc "Push master,master-mco,curbranch, and curbranch-mco"
task push_up: :before do |task, args|
  mco = @current.end_with? "mco"
  mco_name = mco ? @current : @current + "-mco"
  base_name = mco ? @current[0..-5] : @current

  info "Pusing all branches to remote"
  push_all "gamedevnet", "gamedevnet-mco", "master", "master-mco", base_name, mco_name
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
    res << GitHub.make_pr(title)
    wait_range 30, 60 if $delays_enabled
    system "git", "checkout", @current + "-mco"
    res << GitHub.make_pr(title)
  else
    res << GitHub.make_pr(title, suffix: "")
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
  make_branch args.extras[0], "production"
end

desc "Make a new branch based off of MCO"
task new_mco: :before do |task, args|
  make_branch args.extras[0] + "-mco", "production-mco"
end

def make_branch(name, base)
  system "git", "checkout", base
  Git.ensure_branch base
  name = "austin/" + name
  info "Creating #{name} based off of #{base}"
  system "git", "go", name
end

desc "Deploy a set of branches in order"
task :deploy_in_order do |task, args|
  error "You must specify at least two branches" if args.extras.length < 2
  repos = []
  args.extras.each do |arg|
    repos << [arg.split(":")[0],arg.split(":")[1], arg.split(":")[2]]
  end
  str = "The"
  repos[1..-1].each do |repo|
    str += " #{repo[1]} branch of #{repo[0]} and"
  end
  str = str[0..-4]
  str += "will be auto-merged after the #{repos[0][1]} branch of #{repos[0][0]} is finished building"
  info str
  main_repo = repos[0]
  dependants = repos[1..-1]
  if system "gh pr merge #{main_repo[1]} --repo=teamziax/#{main_repo[0]} -d -m"
    wait_range(5,5)
    runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{main_repo[2]} --repo=teamziax/#{main_repo[0]}`)[0]['databaseId']
    if system "gh run watch #{runner_id} --repo=teamziax/#{main_repo[0]} --exit-status"
      dependants.each do |repo|
        if system "gh pr merge #{repo[1]} --repo=teamziax/#{repo[0]} -d -m"
          info "Merged PR for #{repo[0]}"
        else
          error "Failed to merge PR for #{repo[0]}"
        end
      end
    else
      error "Run failed!"
    end
  else
    error "Failed to merge main PR!"
  end
end

desc "Spread out the last N commits over X hours"
task spread_commits: :before do |task, args|
  data = {}
  time = args.extras[1].to_i.hours
  offset = 0
  offset = args.extras[2].to_i.hours unless args.extras[2].nil?
  args.extras[0].to_i.times do |i|
    sha = Git.nth_commit_sha i + 1
    changes = Git.lines_changed sha
    data[sha] = changes
  end
  spread(data, time, Time.now - offset - spread)
end

desc "Spread out all commits from today over X hours"
task spread_today: :before do |task, args|
  data = {}
  time = 1.minute
  start = (Time.now.hour < 4 ? Time.now - 1.day : Time.now).to_date.to_time + rand(8..11).hours + rand(0..60).minutes + rand(0..60).seconds
  commits = Git.commits_after(start.to_date.to_time + 6.hours)
  multiplier = commits.count > 20 ? 0.08 : 0.15
  commits.reverse.each do |sha|
    changes = Git.lines_changed sha
    changes *= rand(0.08..1).ceil if commits.count > 20
    add = (changes.to_f / 7.to_f).ceil
    add += (changes * multiplier).ceil if changes > 75
    time += add.minutes
    data[sha] = changes
  end
  min = Git.last_pushed_date
  start += (start.to_date.to_time + 8.hours) - start unless start.hour > 8
  while time / (60 * 60) > 10
    time -= time * rand(0.01..0.07)
  end
  max = Time.now
  while max > min + 30.seconds && max.hour > 17
    max -= 26.seconds
  end
  while true
    base_under_min = min > start
    start_over_max = start > max
    total_over_max = start + time > max
    raise "Base both above and below min" if base_under_min && start_over_max
    if !base_under_min && !start_over_max && !total_over_max
      break
    end
    if base_under_min
      start += 1.minute
    elsif start_over_max
      start -= 1.minute
    elsif total_over_max
      time -= 1.minutes
    end
  end
  spread(data, time, start)
end

def spread(commits, spread, start_at)
  seconds = spread % 60
  minutes = (spread / 60) % 60
  hours = spread / (60 * 60)
  info "Spreading out #{commits.keys.count} commit(s) across #{format("%02d:%02d:%02d", hours, minutes, seconds)} starting at #{start_at.strftime("%I:%M %p")}"
  total = commits.values.sum
  commits.clone.each do |k,v|
    commits[k] = ((v.to_f/total.to_f) * spread).round
  end
  commit_at = start_at
  conditions = ""
  commits.to_a.reverse.to_h.each do |k,v|
    commit_at += v
    info "#{k[0..6]} will be committed at #{commit_at.strftime("%I:%M:%S %p")}"
    conditions += "\nif [ $GIT_COMMIT = #{k} ]
    then
        export GIT_AUTHOR_DATE=\"#{commit_at}\"
        export GIT_COMMITTER_DATE=\"#{commit_at}\"
    fi"
  end
  FileUtils.rm_rf(Dir.pwd + "/.git/refs/original/")
  system "FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --env-filter '#{conditions}' HEAD~#{commits.keys.count}..HEAD"
  info "Spread out commits"
end