namespace :ustacking do
  desc "Given the diff of the current branch, create pull requests for each commit in the diff"
  task diff: :before do |task, args|
    Git.ensure_clean
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      branches = Git.find_branches_multi(args.extras)
    end
    branches.each do |branch|
      system "git", "checkout", branch
      Git.ensure_clean
      Git.push(force: true)
      create_unique_stacked_prs("production", branch)
      system "git", "checkout", branch
    end
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
      pr_number = get_first_unique_stacked_pr_number("production")
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

  def create_unique_stacked_prs(base, parent)
    info "Creating UNIQUE stacked PRs for #{base}..#{Git.current_branch}"
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
      tmp_branch = "tmp/#{branch.gsub('/', '_')}_#{Time.now.to_i}"
      branches << branch
      info "Creating temporary branch #{tmp_branch} for commit #{commit}"
      error "Failed to create temp branch" unless system "git checkout -b #{tmp_branch} #{base}"
      if system "git cherry-pick --strategy=recursive -X theirs #{commit}"
        pushed = system "git push --force --atomic --no-verify origin #{tmp_branch}:refs/heads/#{branch}"
        if pushed
          pr = GitHub.get_pr_number(branch)
          if pr.nil?
            pr = GitHub.make_pr(friendly_msg, base: base, head: branch)
          else
            GitHub.change_pr_title(branch, friendly_msg)
            GitHub.change_pr_base(branch, base)
          end
          TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "add #{parent} #{Git.repo_name_with_org} #{pr}"})
            conn.send_request("command", {input: "move #{parent} #{Git.repo_name_with_org} #{pr} #{index}"})
            conn.send_request("command", {input: "unpause #{Git.repo_name_with_org} #{pr}"})
          end
        end
        system "git checkout #{base}"
        system "git branch -D #{tmp_branch}"
        error "Failed to push" unless pushed
      else
        system "git checkout #{base}"
        system "git branch -D #{tmp_branch}"
        error "Cherry-pick failed for commit #{commit} in branch #{tmp_branch}"
      end
    end
  end

  def get_first_unique_stacked_pr_number(base)
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
    error "No branches found" if branches.empty?
    Git.find_branches("tmp/ustack/test-").each do |tmp|
      info "Deleting temporary branch #{tmp}"
      system "git", "branch", "-D", tmp
    end
    failed = []
    branches.each do |branch|
      Git.ensure_clean
      system "git", "checkout", branch
      Git.ensure_clean
      cmd = "./gradlew classes"
      # check for microservices directory
      if Dir.exist?("microservices")
        cmd = "./gradlew -p microservices classes && ./gradlew :data-interface:classes"
      end
      commits = Git.my_commits_between("production", branch, "austin")
      commits.each do |commit|
        tmp = "tmp/ustack/test-#{commit}"
        system "git", "checkout", "-b", tmp, "production"
        cherry = system "git cherry-pick -n #{commit}"
        if cherry
          info "Running #{cmd} on commit #{commit} in branch #{tmp}"
          if system(cmd)
            info "Build succeeded for commit #{commit} in branch #{tmp}"
          else
            warning "Build failed for commit #{commit} in branch #{tmp}"
            failed << commit
          end
        else
          warning "Cherry-pick failed for commit #{commit} in branch #{tmp}"
          failed << commit
        end
        system "git", "checkout", branch
        system "git", "branch", "-D", tmp
      end
    end
    if failed.empty?
      info "All builds succeeded"
    else
      error "Build failed for commits: #{failed.join(", ")}"
    end
  end
end
