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
    flags = ""
    # check if we're in rocket-data-platform repo
    if `git remote -v`.include?("rocket-data-platform")
      flags += "-f environment=man1-#{branch == "production" ? "prod" : "dev"}1"
    end
    args.extras.drop(1).each do |query|
      workflows.each do |workflow|
        if workflow.match?(query)
          info "Running workflow #{workflow}"
          sh "gh workflow run #{workflow}.yml --ref #{branch} #{flags}".strip
        end
      end
    end
  end
end
