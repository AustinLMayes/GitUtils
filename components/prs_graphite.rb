# Graphite-flavored variant of components/prs.rb. Commit subject IS the PR
# title, so this is a thin wrapper around `gt submit`.
namespace :gprs do
    desc "Queue a reviewer assignment for the current branch's PR via PRTrain (handles get expanded server-side)"
    task :assign, [:handles] => :before do |task, args|
        handles = [args[:handles], *args.extras].compact.reject(&:empty?)
        raise "Usage: gprs:assign[<handle>[,<handle>...]]" if handles.empty?
        expanded =
          begin
            Reviewers.expand_all(handles, org: Git.repo_org)
          rescue Reviewers::UnknownHandle => e
            error e.message
          end
        branch = Git.current_branch
        pr_number = Graphite.local_pr_numbers[branch]
        if pr_number.nil?
            error "No graphite-tracked PR found for #{branch} in .graphite_pr_info — submit the branch first via gprs:submit"
        end
        TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "assign #{Git.repo_name_with_org} #{pr_number} #{expanded.join(' ')}"})
        end
        info "Queued reviewer assignment for PR ##{pr_number} as #{expanded.inspect}"
    end

    desc "Mark the current branch's PR as QA-bound so the train holds it until QA Passed"
    task bind_qa: :before do |task, args|
        branch = Git.current_branch
        pr_number = Graphite.local_pr_numbers[branch]
        if pr_number.nil?
            error "No graphite-tracked PR found for #{branch} in .graphite_pr_info — submit the branch first via gprs:submit"
        end
        TRAIN.if_connectable do |conn|
            conn.send_request("command", {input: "bind_qa #{Git.repo_name_with_org} #{pr_number}"})
        end
        info "Marked PR ##{pr_number} QA-bound"
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

        branch = Git.current_branch
        repo = Git.repo_name_with_org
        owner = repo.split("/").first
        out = `gh api 'repos/#{repo}/pulls?head=#{owner}:#{branch}&state=open&per_page=1' 2>/dev/null`
        pr_number = out.strip.empty? ? nil : (JSON.parse(out).first&.dig("number"))

        # WORKAROUND: `gt submit` only sets the PR title/description on creation,
        # so an edited commit subject/body never reaches an existing PR. Force
        # both to match the current commit (subject = title, body = body).
        unless pr_number.nil?
            msg = Git.last_commit_message
            unless system("gh", "pr", "edit", pr_number.to_s, "--repo", repo,
                          "--title", msg[:title], "--body", msg[:body], out: File::NULL, err: File::NULL)
                warning "Failed to sync PR ##{pr_number} title/description via gh pr edit"
            end
        end

        system "git", "checkout", @current
        return pr_number
    end
end
