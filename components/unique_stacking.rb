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
      Git.stream nil, "checkout", branch
      Git.ensure_clean
      Git.push(force: true)
      create_unique_stacked_prs("production", branch)
      Git.stream nil, "checkout", branch
    end
  end

  desc "Request review for every commit on the current branch (or the branches specified as arguments)"
  task to_testing: :before do |task, args|
    branches = get_unique_branches(args)
    branches.each do |branch|
      Git.stream nil, "checkout", branch
      commits = Git.my_commits_between("production", Git.current_branch, "austin")
      next if commits.empty?
      Git.stream nil, "checkout", $dev_branch
      Git.ensure_clean
      Git.pull_branches($dev_branch)
      commits.each do |commit|
        unless Git.stream nil, "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", commit
          Git.stream nil, "cherry-pick", "--abort"
          Git.stream nil, "checkout", branch
          error "Cherry-pick failed"
        end
      end
      Git.push
      Git.stream nil, "checkout", branch
      Git.ensure_clean
      commits.each do |commit|
        pr_number = get_pr_number("production", commit)
        if pr_number.nil?
          warning "No stacked PR found for branch #{branch} and commit #{commit}, skipping"
        else
          if train("pr", "to-testing", Git.repo_name_with_org, pr_number)
            train("pr", "unpause", Git.repo_name_with_org, pr_number)
          end
        end
      end
    end
  end

  desc "Resolve all open review conversations on every unique-stacked PR for the given branch(es)"
  task resolve: :before do |task, args|
    branches = get_unique_branches(args)
    branches.each do |branch|
      Git.stream nil, "checkout", branch
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
        results = pr_numbers.map { |n| [n, train("pr", "resolve", Git.repo_name_with_org, n)] }
        report_train_results(results, "Resolved conversations on")
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
    results = pr_numbers.map { |n| [n, train("pr", "assign", Git.repo_name_with_org, n, *expanded)] }
    report_train_results(results, "Assigned #{expanded.inspect} to")
  end

  desc "Mark every PR in the current unique stack as QA-bound so the train holds it until QA Passed"
  task bind_qa: :before do |task, args|
    branch = Git.current_branch
    commits = Git.my_commits_between("production", branch, "austin")
    if commits.empty?
      warning "No unique-stacked commits between production and #{branch}; nothing to bind"
      next
    end
    pr_numbers = commits.filter_map { |c| get_pr_number("production", c) }
    if pr_numbers.empty?
      warning "Found #{commits.length} unique-stacked commits but no PRs for any of them"
      next
    end
    results = pr_numbers.map { |n| [n, train("pr", "bind-qa", Git.repo_name_with_org, n)] }
    report_train_results(results, "QA-bound")
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
    validate_stack_plan(plan.reject { |entry| already_in_base?(entry[:commit], base) })
    base_sha = Git.capture("rev-parse", base).strip

    info "Pushing #{plan.length} unique branch(es), each parented on #{base}"
    pr_numbers = []
    plan.each_with_index do |entry, index|
      sha = cherry_pick_onto_base(entry, base, source_branch)
      if sha == base_sha
        warning "#{entry[:commit][0, 10]} is already in #{base}; skipping #{entry[:branch]}"
        next
      end
      if remote_matches_cherry_pick?(entry[:branch], sha)
        info "#{entry[:branch]} already matches the cherry-pick; skipping push"
      else
        error "Failed to push #{entry[:branch]}" unless GitHub.push_sha(sha, entry[:branch])
      end
      pr_number = sync_stacked_pr(entry, base)
      if pr_number.nil?
        warning "No PR for #{entry[:branch]} — skipping train registration"
        next
      end
      pr_numbers << pr_number
      train_id = "#{parent}-#{entry[:branch].split('/').last}"
      if train("pr", "add", train_id, Git.repo_name_with_org, pr_number)
        train("train", "move", train_id, Git.repo_name_with_org, pr_number, index)
      end
    end
    warn_unassigned(pr_numbers, "ustacking:assign", source_branch)
  end

  def cherry_pick_onto_base(entry, base, source_branch)
    tmp = "tmp/ustack/#{entry[:label].tr('/', '_')}-#{Time.now.to_i}"
    error "Failed to create #{tmp}" unless Git.stream(nil, "checkout", "-q", "-b", tmp, base)
    picked = Git.stream(nil, "cherry-pick", "--strategy=recursive", "-X", "theirs", "--empty=drop", entry[:commit])
    sha = Git.capture("rev-parse", "HEAD").strip
    Git.run(nil, "cherry-pick", "--abort", stderr: :discard) unless picked
    Git.stream nil, "checkout", "-q", source_branch
    Git.run(nil, "branch", "-D", tmp, stderr: :inherit)
    error "Cherry-pick failed for #{entry[:commit]} → #{entry[:branch]}" unless picked
    sha
  end

  # A fresh cherry-pick never shares a sha with the pushed one, so compare what matters: same tree
  # on the same parent. Anything else is a real change and gets pushed.
  def remote_matches_cherry_pick?(branch, sha)
    return false unless Git.ok?(nil, "fetch", "origin", branch, stderr: :discard)
    Git.capture("rev-parse", "FETCH_HEAD^{tree}", "FETCH_HEAD^").strip == Git.capture("rev-parse", "#{sha}^{tree}", "#{sha}^").strip
  end

  def get_pr_number(_base, commit)
    GitHub.open_pr_number(plan_stacked_entry(commit)[:branch])
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
      Git.stream nil, "branch", "-D", tmp
    end
    failed = []
    branches.each do |branch|
      Git.ensure_clean
      Git.stream nil, "checkout", branch
      Git.ensure_clean
      cmd = "./gradlew classes"
      # check for microservices directory
      if Dir.exist?("microservices")
        cmd = "./gradlew -p microservices classes && ./gradlew :data-interface:classes"
      end
      commits = Git.my_commits_between("production", branch, "austin")
      commits.each do |commit|
        tmp = "tmp/ustack/test-#{commit}"
        Git.stream nil, "checkout", "-b", tmp, "production"
        cherry = Git.stream nil, "cherry-pick", "-n", commit
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
        Git.stream nil, "reset", "--hard", "production"
        Git.stream nil, "checkout", branch
        Git.stream nil, "branch", "-D", tmp
      end
    end
    if failed.empty?
      info "All builds succeeded"
    else
      error "Build failed for commits: #{failed.join(", ")}"
    end
  end
end
