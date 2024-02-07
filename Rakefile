require 'common'
require "json"
require 'active_support/time'
require_relative "../RandomScripts/jira"

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
  if to_branch("master")
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

def to_branch(target)
  current  = Git.current_branch
  system "git", "checkout", target
  Git.ensure_branch target
  info "Merging #{current} into #{target}"
  return system "git", "merge", current, "--no-edit"
end

desc "Push master and curbranch"
task push_up: :before do |task, args|
  info "Pusing all branches to remote"
  push_all "master", @current
end

desc "Make a PR from the current branch"
task make_pr: :before do |task, args|
  res = make_prs(args.extras[0], (!args.extras[1].nil? && args.extras[1] == "true"))
  if !res.nil?
    info res
  end
end

desc "Make a PR from the current branch with the last commit as the title"
task make_pr_last: :before do |task, args|
  res = make_prs(Git.last_commit_message, (!args.extras[0].nil? && args.extras[0] == "true"))
  if !res.nil?
    info res
  end
end

desc "Make a PR from the current branch with the branch name as the title"
task make_pr_branch: :before do |task, args|
  branch = Git.current_branch
  branch = branch.split("/").last
  branch = branch.gsub("-", " ").titleize
  res = make_prs(branch, (!args.extras[0].nil? && args.extras[0] == "true"))
  if !res.nil?
    info res
  end
end

desc "Mark a PR as ready for review"
task :pr_ready do |task, args|
  `gh pr ready`
  sleep 5
  `gh pr merge --auto --merge`
end

def make_prs(title, slack)
  res = GitHub.make_pr(title, suffix: "")

  system "git", "checkout", @current
  if slack
    Slack.send_message("#development-prs", res.gsub("\n", " "))
    return nil
  else
    return res
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
    
  }
  by_branch = {}
  unknown = []
  Git.commits_after_last_push.each do |commit|
    message = `git log --format=%B -n 1 #{commit}`.strip.split("\n").first
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
    error "Unknown commits: #{unknown.map{|x| x[0] + " - " + x[1]}.join("\n")}"
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
        if to_branch("master")
          system "git", "checkout", @current
        else
          error "merge failed"
        end
        wait_range 5, 10
        push_all "master"
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

def extract_jira_issues(message)
  message.scan(/CC-\d+/)
end

def transition_issues(sha, comment = nil)
  message = `git log --format=%B -n 1 #{sha}`.strip.split("\n").first
  jiras = extract_jira_issues(message)
  jiras.each do |jira|
    testing_id = -1
    done_id = -1
    status = Jira::Issues.get(jira)["fields"]['status']['name']
    next if status == "Done" || status == "Testing"
    Jira::Issues.transitions(jira)["transitions"].each do |transition|
      next unless transition["isAvailable"] == true
      if transition["name"] == "Testing"
        testing_id = transition["id"]
      elsif transition["name"] == "Done"
        done_id = transition["id"]
      end
    end
    id_to_use = testing_id
    id_to_use = done_id if id_to_use == -1
    if id_to_use == -1
      warn "No transition found for #{jira}"
    end
    Jira::Issues.transition(jira, id_to_use)
    Jira::Issues.add_to_current_sprint(jira, Jira::CC::BOARD_ID)
    recent_comment = TempStorage.is_stored?(jira + "-comment")
    if comment && !recent_comment
      Jira::Issues.add_comment(jira, comment) 
      TempStorage.store(jira + "-comment", "true", expiry: 20.minutes)
    end
    info "Transitioned #{jira}"
    wait_range 5, 10
  end
end

desc "Transition the issues for unpushed commits"
task transition_issues: :before do |task, args|
  Git.commits_after_last_push.each do |commit|
    transition_issues(commit)
  end
end

desc "Set git commit date to author date for n commits"
task :fix_dates do |task, args|
  commits = args.extras[0].to_i
  info "Fixing dates for #{commits} commits"
  system "FILTER_BRANCH_SQUELCH_WARNING=1" "git", "filter-branch", "-f", "--env-filter", "GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE", "HEAD~#{commits}..HEAD"
end

desc "Prepare the stage branch starting at a specific time"
task prepare_stage: :before do |task, args|
  time = Time.now - TimeUtils.parse_time(args.extras[0])
  if Git.branch_exists "austin/stage"
    error "Branch austin/stage already exists!"
  end
  system "git", "stash"
  system "git", "checkout", "production"
  pull_base
  @current = "production"
  make_branch "stage", "production"
  @current = Git.current_branch
  # Loop back through history and stop when we hit the specified time
  start_commit = nil
  `git log --format=%H`.split("\n").each do |commit|
    start_commit = commit
    is_merge = `git log --format=%P -n 1 #{commit}`.strip.split(" ").length > 1
    next unless is_merge
    commit_time_raw = `git log --format=%ct -n 1 #{commit}`.strip
    commit_time = Time.at(commit_time_raw.to_i)
    if commit_time < time
      info "#{commit} is before #{time} (#{commit_time_raw})"
      break
    else
      info "#{commit} is after #{time}"
    end
  end
  system "git", "reset", "--hard", start_commit
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
  branches = [Git.current_branch]
  if args.extras.length > 1
    branches = Git.find_branches_multi(args.extras)
  end
  branches.delete("austin/stage")
  system "git", "stash"
  pull_base unless dont_pull
  branches.each do |branch|
    merge_prod(branch)
  end
  system "git", "stash", "pop"
end

def merge_prod(branch)
  wait_range 5, 10
  info "Merging production into #{branch}"
  system "git", "checkout", branch
  system "git", "pull"
  system "git", "merge", "production", "--no-edit"
  wait_range 5, 10
  if to_branch("master")
    system "git", "checkout", @current
  else
    error "merge failed"
  end
  push_all "master", branch
end

desc "Delete and re-pull the master branch"
task reset_master: :before do |task, args|
  system "git", "stash"
  system "git", "checkout", "production"
  system "git", "branch", "-D", "master"
  system "git", "fetch", "origin", "master:master"
  system "git", "checkout", @current
  system "git", "stash", "pop"
end