require 'common'
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

desc "Run git pull on a selected set of repositories"
task :pull_repos do |task, args|
  FileUtils.act_on_dirs(FileUtils.parse_args(args, 0)) do |dir|
    info "Pulling #{dir}"
    system "git", "stash"
    system "git", "pull"
    system "git", "stash", "pop"
  end
end

desc "Pull all of the selected branches"
task pull_all: :before do |task, args|
  Git.pull_branches *args.extras, ensure_exists: true
  system "git", "checkout", @current
end

desc "Run git pull in the selected directories"
task :pull_dirs do |task, args|
  FileUtils.act_on_dirs(FileUtils.parse_args(args, 0)) do |dir|
    info "Pulling #{dir}"
    Git.safe_checkout *root_branches
    system "git", "pull"
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
  if to_master
    system "git", "checkout", @current
  else
    error "merge failed"
  end
end

def to_master
  current  = Git.current_branch
  target = "master-1.19"
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

desc "Push master and curbranch"
task push_up: :before do |task, args|
  info "Pusing all branches to remote"
  push_all "master-1.19", @current
end

desc "Make a PR from the current branch"
task make_pr: :before do |task, args|
  make_prs(args.extras[0], (!args.extras[1].nil? && args.extras[1] == "true"))
end

desc "Make a PR from the current branch with the last commit as the title"
task make_pr_last: :before do |task, args|
  make_prs(Git.last_commit_message, (!args.extras[0].nil? && args.extras[0] == "true"))
end

desc "Make a PR from the current branch with the branch name as the title"
task make_pr_branch: :before do |task, args|
  branch = Git.current_branch
  branch = branch.split("/").last
  branch = branch.gsub("-", " ").titleize
  make_prs(branch, (!args.extras[0].nil? && args.extras[0] == "true"))
end

def make_prs(title, slack)
  res = "@here "
  res << GitHub.make_pr(title, suffix: "")

  system "git", "checkout", @current
  if slack
    Slack.send_message("#development-prs", res.gsub("\n", " "))
  else
    info res
  end
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

desc "Merge production into the current branch"
task merge_prod: :before do |task, args|
  dont_pull = args.extras[0] == "false"
  system "git", "stash"
  merge_prod(dont_pull)
  system "git", "stash", "pop"
end

def merge_prod(dont_pull)
  unless dont_pull
    system "git", "pull"
    pull_base
  end
  info "Merging production into #{@current}"
  system "git", "checkout", @current
  system "git", "merge", "production", "--no-edit"
  if to_master
    system "git", "checkout", @current
  else
    error "merge failed"
  end
  push_all "master-1.19", @current
end

desc "Delete and re-pull the master-1.19 branch"
task reset_master: :before do |task, args|
  system "git", "stash"
  system "git", "checkout", "production"
  system "git", "branch", "-D", "master-1.19"
  system "git", "fetch", "origin", "master-1.19:master-1.19"
  system "git", "checkout", @current
  system "git", "stash", "pop"
end