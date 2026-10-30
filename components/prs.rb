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
                train("pr", "add", branch, Git.repo_name_with_org, res)
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
                train("pr", "add", branch, Git.repo_name_with_org, res)
            end
        end
    end

    desc "Push the current branch (or each branch in args), open a draft PR from its last commit, and register it with the train"
    task submit: :before do |task, args|
        branches = get_non_stacked_branches(args)
        Git.act_on_branches *branches, ensure_exists: true do |branch|
            Git.push(force: true)
            res = make_prs(Git.last_commit_message.values.join("\n"))
            if !res.nil?
                info res
                train("pr", "add", branch, Git.repo_name_with_org, res)
                warn_unassigned([res], "prs:assign", branch)
            end
        end
    end

    desc "Queue a reviewer assignment for the current branch's PR via PRTrain (handles get expanded server-side)"
    task :assign, [:handles] => :before do |task, args|
        handles = [args[:handles], *args.extras].compact.reject(&:empty?)
        raise "Usage: prs:assign[<handle>[,<handle>...]]" if handles.empty?
        expanded =
          begin
            Reviewers.expand_all(handles, org: Git.repo_org)
          rescue Reviewers::UnknownHandle => e
            error e.message
          end
        branch = Git.current_branch
        pr_number = GitHub.open_pr_number(branch)
        error "No open PR found for #{branch} — submit the branch first via prs:submit" if pr_number.nil?
        train("pr", "assign", Git.repo_name_with_org, pr_number, *expanded)
    end

    desc "Mark the current branch's PR as QA-bound so the train holds it until QA Passed"
    task bind_qa: :before do |task, args|
        branch = Git.current_branch
        pr_number = GitHub.open_pr_number(branch)
        error "No open PR found for #{branch} — submit the branch first via prs:submit" if pr_number.nil?
        # `ax` reports the outcome itself, including the refusal when nothing is linked — the case
        # that left two PRs QA-bound with no issue for weeks. A second line here would either
        # duplicate it or contradict it.
        train("pr", "bind-qa", Git.repo_name_with_org, pr_number)
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
            res = GitHub.make_pr(title, suffix: "", body: body, draft: true)
        end

        Git.stream nil, "checkout", @current
        return res
    end
end
