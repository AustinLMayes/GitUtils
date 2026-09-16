namespace :train do
  desc "Start a train off of a specified branch"
  task start: :before do |task, args|
    branch = args.extras[0]
    error "Branch name is required" if branch.nil?
    num = GitHub.get_pr_number(branch, only_mine: false)
    error "No PR found for branch #{branch}" if num.nil?
    repo = Git.repo_name_with_org
    # Stop at the first failure. The rest only make sense against a PR that is actually in the
    # train, and firing them anyway is how a half-started train looks started.
    next unless train("pr", "add", branch, repo, num)
    next unless train("pr", "unpause", repo, num)

    # The translations train is automated end-to-end — bump its priority so it
    # outranks any concurrent feature trains in spread/expedite, and pre-stage
    # the `dev` team as the intended reviewer so the next request_review tick
    # assigns + pings them via Graphite without manual intervention.
    if branch == "translations"
      train("train", "priority", branch, 50)
      train("pr", "assign", repo, num, "dev")
    end
  end
end
