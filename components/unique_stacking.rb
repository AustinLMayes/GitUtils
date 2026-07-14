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

  desc "Request review for every commit on the current branch (or the branches specified as arguments)"
  task to_testing: :before do |task, args|
    branches = get_unique_branches(args)
    branches.each do |branch|
      system "git", "checkout", branch
      commits = Git.my_commits_between("production", Git.current_branch, "austin")
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

  desc "Assign reviewers (team / person shorthands) to every PR in the current unique stack via PRTrain"
  task :assign, [:handles] => :before do |task, args|
    handles = [args[:handles], *args.extras].compact.reject(&:empty?)
    raise "Usage: ustacking:assign[<handle>[,<handle>...]]" if handles.empty?
    expanded =
      begin
        Reviewers.expand_all(handles, org: Git.repo_org)
      rescue Reviewers::UnknownHandle => e
        error e.message
      end
    branch = Git.current_branch
    commits = Git.my_commits_between("production", branch, "austin")
    if commits.empty?
      warning "No unique-stacked commits between production and #{branch}; nothing to assign"
      next
    end
    pr_numbers = commits.filter_map { |c| get_pr_number("production", c) }
    if pr_numbers.empty?
      warning "Found #{commits.length} unique-stacked commits but no PRs for any of them"
      next
    end
    TRAIN.if_connectable do |conn|
      pr_numbers.each do |pr_number|
        conn.send_request("command", {input: "assign #{Git.repo_name_with_org} #{pr_number} #{expanded.join(' ')}"})
      end
    end
    info "Queued reviewer assignment for #{pr_numbers.length} unique-stacked PR(s): ##{pr_numbers.join(', ')} as #{expanded.inspect}"
  end

  def create_unique_stacked_prs(base, parent)
    source_branch = Git.current_branch
    info "Creating UNIQUE stacked PRs for #{base}..#{source_branch}"
    commits = Git.my_commits_between(base, source_branch, "austin")
    if commits.empty?
      warning "No commits between #{base} and #{source_branch}"
      return
    end

    plan = commits.map { |commit| plan_stacked_entry(commit) }

    system "git", "fetch", "origin", base

    info "Materializing #{plan.length} unique branch(es), each parented on #{base}"
    plan.each do |entry|
      if stacked_branch_up_to_date?(entry[:branch], entry[:commit], entry[:message], base)
        info "#{entry[:branch]} already matches source commit on top of #{base}; skipping rebuild"
        system "git", "checkout", entry[:branch]
      else
        system "git", "branch", "-D", entry[:branch], out: File::NULL, err: File::NULL if Git.branch_exists(entry[:branch])
        error "Failed to create #{entry[:branch]}" unless system("git", "checkout", "-b", entry[:branch], base)
        unless system("git", "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", entry[:commit])
          system "git", "cherry-pick", "--abort"
          error "Cherry-pick failed for #{entry[:commit]} → #{entry[:branch]}"
        end
        error "Failed to amend commit message for #{entry[:branch]}" unless system("git", "commit", "--amend", "-m", entry[:message])
      end
      system("gt", "track", "--parent", base, "--no-interactive", out: File::NULL, err: File::NULL)

      # Each ustacking sub-branch submits individually (no shared chain to
      # bundle). --force overrides graphite's "remote SHA changed" guard.
      begin
        Graphite.submit(force: true)
      rescue Graphite::Error => e
        system "git", "checkout", source_branch
        error "gt submit failed for #{entry[:branch]}: #{e.message}"
      end
    end

    system "git", "checkout", source_branch

    pr_numbers_by_branch = Graphite.local_pr_numbers
    plan.each_with_index do |entry, index|
      pr_number = pr_numbers_by_branch[entry[:branch]]
      if pr_number.nil?
        warning "No PR number found for #{entry[:branch]} in .graphite_pr_info — skipping train registration"
        next
      end
      train = "#{parent}-#{entry[:branch].split('/').last}"
      TRAIN.if_connectable do |conn|
        conn.send_request("command", {input: "add #{train} #{Git.repo_name_with_org} #{pr_number}"})
        conn.send_request("command", {input: "move #{train} #{Git.repo_name_with_org} #{pr_number} #{index}"})
      end
    end
  end

  def get_pr_number(_base, commit)
    Graphite.local_pr_numbers[plan_stacked_entry(commit)[:branch]]
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
