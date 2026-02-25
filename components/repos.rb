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

  desc "Cancel all matching workflows on the current branch"
  task :cancel_workflows do |task, args|
    error "You must run this in the root of the repo" unless File.exists?(".github/workflows")
    branch = args.extras[0]
    branch = Git.current_branch if branch == "c"
    workflows = Dir.glob(".github/workflows/*.yml").map { |f| File.basename(f, ".yml") }
    workflows += Dir.glob(".github/workflows/*.yaml").map { |f| File.basename(f, ".yaml") }
    error "No workflows found" if workflows.empty?
    args.extras.drop(1).each do |query|
      query = Regexp.new(query, Regexp::IGNORECASE)
      workflows.each do |workflow|
        if workflow.match?(query)
          info "Canceling workflow #{workflow}"
          # gh run list --workflow=WORKFLOW_NAME --branch=BRANCH_NAME --json=id --jq '.[].id' --status=in_progress
          flows = []
          %w(in_progress queued requested waiting pending).each do |status|
            res = `gh run list --workflow=#{workflow}.yml --branch=#{branch} --json=databaseId --jq '.[].databaseId' --status=#{status}`
            flows += res.split("\n").map(&:strip).reject(&:empty?)
          end
          flows.each do |id|
            info "Canceling run #{id} for workflow #{workflow}"
            system "gh", "run", "cancel", id
          end
        end
      end
    end
  end
end
