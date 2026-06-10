namespace :r do
  desc "Run git pull on a selected set of repositories"
  task :pull do |task, args|
    FileUtils.act_on_dirs(FileUtils.parse_args(args, 0)) do |dir|
      info "Pulling #{dir}"
      system "git", "stash"
      system "git", "pull"
      system "git", "stash", "pop"
    end
  end

  desc "Run git pull in the selected directories"
  task :pull_dirs do |task, args|
    FileUtils.act_on_dirs(FileUtils.parse_args(args, 0)) do |dir|
      info "Pulling #{dir}"
      Git.safe_checkout *root_branches
      system "git", "pull"
    end
  end

  desc "Run all matching workflows on the current branch"
  task :run_workflows do |task, args|
    error "You must run this in the root of the repo" unless File.exists?(".github/workflows")
    branch = args.extras[0]
    branch = Git.current_branch if branch == "c"
    workflows = Dir.glob(".github/workflows/*.yml").map { |f| File.basename(f, ".yml") }
    workflows += Dir.glob(".github/workflows/*.yaml").map { |f| File.basename(f, ".yaml") }
    error "No workflows found" if workflows.empty?
    flags = ""
    if `git remote -v`.include?("rocket-data-platform")
      flags += "-f environment=man1-#{branch == "production" ? "prod" : "dev"}1"
    end
    args.extras.drop(1).each do |query|
      query = Regexp.new(query, Regexp::IGNORECASE)
      workflows.each do |workflow|
        if workflow.match?(query)
          info "Running workflow #{workflow}"
          if workflow.include? "publish"
            sh "gh workflow run #{workflow}.yml --ref #{branch}".strip
          else
            sh "gh workflow run #{workflow}.yml --ref #{branch} #{flags}".strip
          end
        end
      end
    end
  end

  desc "Cancel all workflows on the given branches"
  task :cancel_all do |task, args|
    branches = parse_branch_args(args.extras)
    branches.each do |branch|
      cancel_runs(branch, active_runs(branch))
    end
  end

  desc "Cancel all matching workflows on the given branches"
  task :cancel_workflows do |task, args|
    branches = parse_branch_arg(args.extras[0])
    queries = args.extras.drop(1).map { |q| Regexp.new(q, Regexp::IGNORECASE) }
    error "No workflow queries provided" if queries.empty?
    branches.each do |branch|
      matching = active_runs(branch).select do |run|
        queries.any? { |q| run["workflowName"].match?(q) }
      end
      cancel_runs(branch, matching)
    end
  end

  def parse_branch_arg(spec)
    return [Git.current_branch] if spec.nil? || spec == "c"
    return remote_branches_matching("^austin\\/.*") if spec == "all"
    resolve_remote_branches(spec.split("+"))
  end

  def parse_branch_args(extras)
    return [Git.current_branch] if extras.empty?
    return remote_branches_matching("^austin\\/.*") if extras[0] == "all" && extras[1].nil?
    resolve_remote_branches(extras)
  end

  def all_remote_branches
    return @all_remote_branches if defined?(@all_remote_branches)
    repo = Git.repo_name_with_org
    info "Fetching branch list from #{repo}"
    res = `gh api --paginate "/repos/#{repo}/branches?per_page=100" --jq '.[].name'`
    @all_remote_branches = res.split("\n").map(&:strip).reject(&:empty?)
  end

  def remote_branches_matching(pattern)
    all_remote_branches.select { |b| b.match?(/#{pattern}/) }
  end

  def resolve_remote_branches(names)
    branches = all_remote_branches
    names.flat_map do |n|
      matches = branches.select { |b| b.match?(/#{n}/) }
      matches.empty? ? [n] : matches
    end.uniq
  end

  def active_runs(branch)
    runs = []
    %w(in_progress queued requested waiting pending).each do |status|
      res = `gh run list --branch=#{branch} --status=#{status} --json=databaseId,workflowName,status --limit=200`
      parsed = JSON.parse(res) rescue []
      runs += parsed
    end
    runs.uniq { |r| r["databaseId"] }
  end

  def cancel_runs(branch, runs)
    if runs.empty?
      info "No active runs on #{branch}"
      return
    end
    repo = Git.repo_name_with_org
    runs.each do |run|
      id = run["databaseId"].to_s
      info "Canceling run #{id} (#{run["workflowName"]}, #{run["status"]}) on #{branch}"
      if %w(queued requested waiting pending).include?(run["status"])
        system "gh", "api", "-X", "POST", "/repos/#{repo}/actions/runs/#{id}/force-cancel"
      else
        system "gh", "run", "cancel", id
      end
    end
  end
end
