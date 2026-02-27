namespace :train do
  desc "Start a treain off of a specified branch"
  task start: :before do |task, args|
    branch = args.extras[0]
    error "Branch name is required" if branch.nil?
    num = GitHub.get_pr_number(branch, only_mine: false)
    error "No PR found for branch #{branch}" if num.nil?
    TRAIN.if_connectable do |conn|
      conn.send_request("command", {input: "add #{branch} #{Git.repo_name_with_org} #{num}"})
      conn.send_request("command", {input: "unpause #{Git.repo_name_with_org} #{num}"})
    end
  end
end
