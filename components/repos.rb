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
end
