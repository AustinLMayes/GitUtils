
namespace :prs do
    desc "Make a PR from the current branch"
    task new: :before do |task, args|
        res = make_prs(args.extras[0], (!args.extras[1].nil? && args.extras[1] == "true"))
        if !res.nil?
            info res
        end
    end

    desc "Make a PR from the current branch with the last commit as the title"
    task last: :before do |task, args|
        res = make_prs(Git.last_commit_message, (!args.extras[0].nil? && args.extras[0] == "true"))
        if !res.nil?
            info res
        end
    end

    desc "Make a PR from the current branch with the branch name as the title"
    task branch: :before do |task, args|
        branch = Git.current_branch
        branch = branch.split("/").last
        branch = branch.gsub("-", " ").titleize
        res = make_prs(branch, (!args.extras[0].nil? && args.extras[0] == "true"))
        if !res.nil?
            info res
        end
    end

    desc "Mark a PR as ready for review"
    task :ready do |task, args|
        `gh pr ready`
        sleep 5
        `gh pr merge --auto --merge`
    end

    def make_prs(title, slack)
        res = GitHub.make_pr(title, suffix: "")

        system "git", "checkout", @current
        if slack
            Slack.send_message("#development-prs", res.gsub("\n", " "))
            return nil
        else
            return res
        end
    end
end