namespace :stacking do
  def base_stacking_branch
    ENV["MAIN_BRANCH"] || "production"
  end

  desc "Given the diff of the current branch, create pull requests for each commit in the diff"
  task diff: :before do |task, args|
    current = Git.current_branch
    Git.ensure_clean
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      branches = Git.find_branches_multi(args.extras)
    end
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
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      branches = Git.find_branches_multi(args.extras)
    end
    branches.each do |branch|
      system "git", "checkout", branch
      first = get_first_commit(base_stacking_branch)
      next if first.nil?
      system "git", "checkout", $dev_branch
      Git.ensure_clean
      unless system "git", "cherry-pick", "--empty=drop", "--strategy=recursive", "-X theirs", first
        system "git", "cherry-pick", "--abort"
        system "git", "checkout", branch
        error "Cherry-pick failed"
      end
      Git.push
      system "git", "checkout", branch
      Git.ensure_clean
      pr_number = get_first_stacked_pr_number(base_stacking_branch)
      if pr_number.nil?
        warning "No stacked PR found for branch #{branch}"
      else
        TRAIN.if_connectable do |conn|
          conn.send_request("command", {input: "to_testing #{Git.repo_name_with_org} #{pr_number}"})
        end
        info "Moved PR ##{pr_number} to dev"
      end
    end
  end

  def create_stacked_prs(base, parent)
    info "Creating stacked PRs for #{base}..#{Git.current_branch}"
    commits = Git.my_commits_between(base, Git.current_branch, "austin")
    branches = []
    info "Creating PRs for #{commits.length} commits"
    max_commits = ENV["MAX_STACKED_COMMITS"] ? ENV["MAX_STACKED_COMMITS"].to_i : 5
    commits.each_with_index do |commit, index|
      if index >= max_commits
        warning "Reached maximum of #{max_commits} stacked commits, stopping"
        break
      end
      msg = `git log -1 --pretty=format:%s #{commit}`
      friendly_msg = msg.split("\n").first.split(" ")[1..-1].join(" ")
      branch = msg.split(" ").first
      branch = "austin/#{branch}" unless branch.start_with?("austin/")
      branches << branch
      error "Failed to push" unless system "git push --force --atomic --no-verify origin #{commit}:refs/heads/#{branch}"
      pr = GitHub.get_pr_number(branch)
      if pr.nil?
        pr = GitHub.make_pr(friendly_msg, base: base, head: branch)
      else
        GitHub.change_pr_base(branch, base)
        GitHub.change_pr_title(branch, friendly_msg)
      end
      TRAIN.if_connectable do |conn|
        conn.send_request("command", {input: "add #{parent} #{Git.repo_name_with_org} #{pr}"})
        conn.send_request("command", {input: "move #{parent} #{Git.repo_name_with_org} #{pr} #{index}"})
        conn.send_request("command", {input: "unpause #{Git.repo_name_with_org} #{pr}"})
      end
      base = branch
    end
  end

  def get_first_stacked_pr_number(base)
    first_commit = get_first_commit(base)
    return nil if first_commit.nil?
    msg = `git log -1 --pretty=format:%s #{first_commit}`
    branch = msg.split(" ").first
    branch = "austin/#{branch}" unless branch.start_with?("austin/")
    GitHub.get_pr_number(branch)
  end

  def get_first_commit(base)
    commits = Git.my_commits_between(base, Git.current_branch, "austin")
    commits.empty? ? nil : commits.first
  end

  desc "Run ./gradlew classes on all commits in the current branch"
  task build: :before do |task, args|
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      branches = Git.find_branches_multi(args.extras)
    end
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
  
  desc "Find orphaned PRs"
  task orphaned: :before do |task, args|
    prs = GitHub.get_my_prs
    if prs.nil? || prs.empty?
      info "No PRs found"
      return
    end
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      branches = Git.find_branches_multi(args.extras)
    end
    info "Validating #{prs.length} PRs"
    commit_branches = []
    branches.each do |branch|
      system "git", "checkout", branch
      Git.ensure_clean
      commits = Git.my_commits_between(base_stacking_branch, branch, "austin")
      commit_branches += commits.map do |commit|
        msg = `git log -1 --pretty=format:%s #{commit}`
        branch = msg.split(" ").first
        branch = "austin/#{branch}" unless branch.start_with?("austin/")
        branch
      end
    end
    commit_branches = commit_branches.uniq
    found_prs = prs.select {|pr| commit_branches.include? pr[:branch] }
    not_found_prs = prs.select {|pr| !commit_branches.include? pr[:branch] }
    not_found_commits = commit_branches.select { |branch| prs.none? { |pr| pr[:branch] == branch } }
    not_found_prs.each do |pr|
      warning "Found orphaned PR #{pr[:url]} for branch #{pr[:branch]}"
    end
    not_found_commits.each do |branch|
      warning "Found orphaned commit #{branch} for branch #{branch}"
    end
    found_prs.each do |pr|
      info "Found PR #{pr[:url]} for branch #{pr[:branch]}"
    end
  end
end
