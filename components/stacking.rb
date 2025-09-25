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
      create_stacked_prs(base_stacking_branch)
      system "git", "checkout", branch
      system "git", "pu", "--force"
    end
    system "git checkout #{current}"
  end

  def create_stacked_prs(base)
    info "Creating stacked PRs for #{base}..#{Git.current_branch}"
    commits = Git.my_commits_between(base, Git.current_branch, "austin")
    branches = []
    info "Creating PRs for #{commits.length} commits"
    commits.each do |commit|
      msg = `git log -1 --pretty=format:%s #{commit}`
      friendly_msg = msg.split("\n").first.split(" ")[1..-1].join(" ")
      branch = msg.split(" ").first
      branch = "austin/#{branch}" unless branch.start_with?("austin/")
      branches << branch
      error "Failed to push" unless system "git push --force --atomic --no-verify origin #{commit}:refs/heads/#{branch}"
      pr = GitHub.get_pr_number(branch)
      if pr.nil?
        GitHub.make_pr(friendly_msg, base: base, head: branch)
      end
      GitHub.change_pr_base(branch, base)
      GitHub.change_pr_title(branch, friendly_msg)
      base = branch
    end
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
