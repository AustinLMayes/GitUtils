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
      to_move = ENV["MAX_TESTING_COMMITS"] ? ENV["MAX_TESTING_COMMITS"].to_i : 1
      to_move = [to_move, commits.length].min
      commits = commits[0...to_move]
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
        TRAIN.if_connectable do |conn|
          pr_numbers.each do |pr_number|
            conn.send_request("command", {input: "unpause #{Git.repo_name_with_org} #{pr_number}"})
            conn.send_request("command", {input: "to_testing #{Git.repo_name_with_org} #{pr_number}"})
          end
        end
        info "Moved PR ##{pr_numbers.join(", ")} to testing"
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
      msg = Git.commit_message(commit)
      friendly_msg = msg[:title].split(" ")[1..-1].join(" ")
      body = msg[:body]
      branch = msg[:title].split(" ").first
      branch = "austin/#{branch}" unless branch.start_with?("austin/")
      branches << branch
      error "Failed to push" unless system "git push --force --atomic --no-verify origin #{commit}:refs/heads/#{branch}"
      pr = GitHub.get_pr_number(branch)
      if pr.nil?
        pr = GitHub.make_pr(friendly_msg, base: base, head: branch, train: parent, body: body)
      else
        GitHub.change_pr_base(branch, base)
        GitHub.change_pr_title(branch, friendly_msg)
        GitHub.change_pr_body(branch, body)
      end
      TRAIN.if_connectable do |conn|
        conn.send_request("command", {input: "add #{parent} #{Git.repo_name_with_org} #{pr}"})
        conn.send_request("command", {input: "move #{parent} #{Git.repo_name_with_org} #{pr} #{index}"})
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

  def get_stacked_pr_number(commit)
    msg = `git log -1 --pretty=format:%s #{commit}`
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
  
  desc "Find orphaned PRs"
  task orphaned: :before do |task, args|
    prs = GitHub.get_my_prs
    if prs.nil? || prs.empty?
      info "No PRs found"
      return
    end
    branches = get_branches(args)
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
