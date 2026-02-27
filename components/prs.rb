
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
        res = make_prs(Git.last_commit_message)
        if !res.nil?
            info res
        end
    end

    desc "Make a PR from the current branch with the branch name as the title"
    task branch: :before do |task, args|
        branch = Git.current_branch
        branch = branch.split("/").last
        branch = branch.gsub("-", " ").titleize
        res = make_prs(branch)
        if !res.nil?
            info res
        end
    end

    def make_prs(title)
        res = GitHub.make_pr(title, suffix: "")

        system "git", "checkout", @current
        return res
    end
end
