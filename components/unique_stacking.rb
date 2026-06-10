namespace :ustacking do
  def get_unique_branches(args)
    branches = [Git.current_branch]
    unless args.extras[0].nil?
      if args.extras[0] == "all" && args.extras[1].nil?
        branches = Git.find_branches("austin/u/.*$")
      else
        branches = Git.find_branches_multi(args.extras)
      end
    end
    branches
  end

  desc "Given the diff of the current branch, create pull requests for each commit in the diff"
  task diff: :before do |task, args|
    Git.ensure_clean
    branches = get_unique_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      Git.ensure_clean
      Git.push(force: true)
      create_unique_stacked_prs("production", branch)
      system "git", "checkout", branch
    end
  end

  desc "Request review for the first 5 (or MAX_STACKED_COMMITS) commits in the current branch, or the branches specified as arguments"
  task to_testing: :before do |task, args|
    branches = get_unique_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      max_stacked = ENV["MAX_STACKED_COMMITS"] ? ENV["MAX_STACKED_COMMITS"].to_i : 5
      commits = Git.my_commits_between("production", Git.current_branch, "austin")
      if commits.length > max_stacked
        warning "Branch #{branch} has #{commits.length} commits, which exceeds the maximum of #{max_stacked} stacked commits. Only the first #{max_stacked} commits will be included in the stacked PRs."
        commits = commits[0...max_stacked]
      end
      next if commits.empty?
      system "git", "checkout", $dev_branch
      Git.ensure_clean
      Git.pull_branches($dev_branch)
      commits.each do |commit|
        unless system "git", "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", commit
          system "git", "cherry-pick", "--abort"
          system "git", "checkout", branch
          error "Cherry-pick failed"
        end
      end
      Git.push
      system "git", "checkout", branch
      Git.ensure_clean
      commits.each do |commit|
        pr_number = get_pr_number("production", commit)
        if pr_number.nil?
          warning "No stacked PR found for branch #{branch} and commit #{commit}, skipping"
        else
          TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "to_testing #{Git.repo_name_with_org} #{pr_number}"})
            conn.send_request("command", {input: "unpause #{Git.repo_name_with_org} #{pr_number}"})
          end
          info "Moved PR ##{pr_number} to dev"
        end
      end
    end
  end

  desc "Resolve all open review conversations on every unique-stacked PR for the given branch(es)"
  task resolve: :before do |task, args|
    branches = get_unique_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      commits = Git.my_commits_between("production", branch, "austin")
      next if commits.empty?
      pr_numbers = []
      commits.each do |commit|
        pr_number = get_pr_number("production", commit)
        if pr_number.nil?
          warning "No stacked PR found for branch #{branch} and commit #{commit}, skipping"
        else
          pr_numbers << pr_number
        end
      end
      if pr_numbers.empty?
        warning "No unique-stacked PRs found for branch #{branch}"
      else
        TRAIN.if_connectable do |conn|
          pr_numbers.each do |pr_number|
            conn.send_request("command", {input: "resolve_conversations #{Git.repo_name_with_org} #{pr_number}"})
          end
        end
        info "Queued resolve of conversations on PR ##{pr_numbers.join(", ")}"
      end
    end
  end

  def create_unique_stacked_prs(base, parent)
    info "Creating UNIQUE stacked PRs for #{base}..#{Git.current_branch}"
    commits = Git.my_commits_between(base, Git.current_branch, "austin")
    branches = []
    info "Creating PRs for #{commits.length} commits"
    commits.each_with_index do |commit, index|
      msg = Git.commit_message(commit)
      friendly_msg = msg[:title].split(" ")[1..-1].join(" ")
      body = msg[:body]
      branch = msg[:title].split(" ").first
      branch = "austin/#{branch}" unless branch.start_with?("austin/")
      tmp_branch = "tmp/#{branch.gsub('/', '_')}_#{Time.now.to_i}"
      branches << branch
      info "Creating temporary branch #{tmp_branch} for commit #{commit}"
      error "Failed to create temp branch" unless system "git checkout -b #{tmp_branch} #{base}"
      if system "git cherry-pick --strategy=recursive -X theirs #{commit}"
        needs_push = true
        if system("git fetch origin #{branch}", out: File::NULL, err: File::NULL)
          local_tree = `git rev-parse HEAD^{tree}`.strip
          local_parent = `git rev-parse HEAD^`.strip
          remote_tree = `git rev-parse FETCH_HEAD^{tree}`.strip
          remote_parent = `git rev-parse FETCH_HEAD^`.strip
          if local_tree == remote_tree && local_parent == remote_parent
            info "Remote #{branch} already matches local cherry-pick; skipping push"
            needs_push = false
          end
        end
        pushed = needs_push ? system("git push --force --atomic --no-verify origin #{tmp_branch}:refs/heads/#{branch}") : true
        if pushed
          pr = GitHub.get_pr_number(branch)
          train = parent + "-" + branch.split("/").last
          if pr.nil?
            pr = GitHub.make_pr(friendly_msg, base: base, head: branch, train: train, body: body)
          else
            GitHub.change_pr_title(branch, friendly_msg)
            GitHub.change_pr_base(branch, base)
            GitHub.change_pr_body(branch, body)
          end
          TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "add #{train} #{Git.repo_name_with_org} #{pr}"})
            conn.send_request("command", {input: "move #{train} #{Git.repo_name_with_org} #{pr} #{index}"})
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

  def get_pr_number(base, commit)
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
    branches = get_unique_branches(args)
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
        system "git", "reset", "--hard", "production"
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
