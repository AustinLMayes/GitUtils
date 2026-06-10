namespace :prs do
    desc "Make a PR from the current branch"
    task new: :before do |task, args|
        res = make_prs(args.extras[0])
        if !res.nil?
            info res
        end
    end

    desc "Make a PR from the current branch with the last commit as the title"
    task last: :before do |task, args|
        branches = get_non_stacked_branches(args)
        Git.act_on_branches *branches, ensure_exists: true do |branch|
            res = make_prs(Git.last_commit_message.values.join("\n"))
            if !res.nil?
                info res
                TRAIN.if_connectable do |conn|
                    conn.send_request("command", {input: "add #{branch} #{Git.repo_name_with_org} #{res}"})
                end
            end
        end
    end

    desc "Make a PR from the current branch with the branch name as the title"
    task branch: :before do |task, args|
        branches = get_non_stacked_branches(args)
        Git.act_on_branches *branches, ensure_exists: true do |branch|
            title = branch.split("/").last.gsub("-", " ").titleize
            res = make_prs(title)
            if !res.nil?
                info res
                TRAIN.if_connectable do |conn|
                    conn.send_request("command", {input: "add #{branch} #{Git.repo_name_with_org} #{res}"})
                end
            end
        end
    end

    def make_prs(message)
        lines = message.strip.split("\n")
        title = lines.first
        if title.empty?
            error "Cannot create PR with empty title"
            return nil
        end
        body = " "
        if lines.length > 1
            body = lines[1..-1].join("\n")
        end
        res = GitHub.get_pr_number(Git.current_branch)
        if !res.nil?
            GitHub.change_pr_title(Git.current_branch, title)
            GitHub.change_pr_body(Git.current_branch, body)
        else
            res = GitHub.make_pr(title, suffix: "", body: body)
        end

        system "git", "checkout", @current
        return res
    end
end
