namespace :train do
  desc "Start a train off of a specified branch"
  task start: :before do |task, args|
    branch = args.extras[0]
    error "Branch name is required" if branch.nil?
    num = GitHub.get_pr_number(branch, only_mine: false)
    error "No PR found for branch #{branch}" if num.nil?
    repo = Git.repo_name_with_org
    TRAIN.if_connectable do |conn|
      conn.send_request("command", {input: "add #{branch} #{repo} #{num}"})
      conn.send_request("command", {input: "unpause #{repo} #{num}"})
      # The translations train is automated end-to-end — bump its priority so it
      # outranks any concurrent feature trains in spread/expedite, and pre-stage
      # the `dev` team as the intended reviewer so the next request_review tick
      # assigns + pings them via Graphite without manual intervention.
      if branch == "translations"
        conn.send_request("command", {input: "priority #{branch} 50"})
        conn.send_request("command", {input: "assign #{repo} #{num} dev"})
      end
    end
  end
end
