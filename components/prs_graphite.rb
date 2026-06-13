# Graphite-flavored variant of components/prs.rb. Commit subject IS the PR
# title, so this is a thin wrapper around `gt submit`.
namespace :gprs do
    desc "Queue a reviewer assignment for the current branch's PR via PRTrain (handles get expanded server-side)"
    task :assign, [:handles] => :before do |task, args|
        handles = [args[:handles], *args.extras].compact.reject(&:empty?)
        raise "Usage: gprs:assign[<handle>[,<handle>...]]" if handles.empty?
        Reviewers.expand_all(handles, org: Git.repo_org) # raises on typo
        branch = Git.current_branch
        pr_number = Graphite.local_pr_numbers[branch]
        if pr_number.nil?
            error "No graphite-tracked PR found for #{branch} in .graphite_pr_info — submit the branch first via gprs:submit"
        end
        TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "assign #{Git.repo_name_with_org} #{pr_number} #{handles.join(' ')}"})
        end
        info "Queued reviewer assignment for PR ##{pr_number}: #{handles.inspect}"
    end

    desc "Submit the current branch (or each branch in args) via Graphite"
    task submit: :before do |task, args|
        branches = get_non_stacked_branches(args)
        Git.act_on_branches *branches, ensure_exists: true do |branch|
            res = make_prs_gt
            if !res.nil?
                info res
                TRAIN.if_connectable do |conn|
                    conn.send_request("command", {input: "add #{branch} #{Git.repo_name_with_org} #{res}"})
                end
            end
        end
    end

    def make_prs_gt
        # Idempotent — silent no-op if already tracked.
        system("gt", "track", "--parent", "production", "--no-interactive",
               out: File::NULL, err: File::NULL)

        begin
            Graphite.submit
        rescue Graphite::Error => e
            error "gt submit failed: #{e.message}"
            return nil
        end

        # gt submit doesn't return the PR number parseably; look it up via gh.
        branch = Git.current_branch
        pr_number = `gh pr list --head #{branch} --state open --json number --jq '.[0].number'`.strip

        system "git", "checkout", @current
        return pr_number.empty? ? nil : pr_number.to_i
    end
end
