require "cgi"
require "json"

# Workflow-run verbs we kept hand-rolling as raw `gh api -X POST`.
#
# Read (pending, status) and write (approve, rerun) stay separate on purpose — only the write half
# needs authorization, so the read half stays freely runnable. Don't fold them together.
#
# A PR opened by github-actions[bot] parks every run at `conclusion: action_required`, so a context
# the base ruleset requires ends up absent rather than red. GitHub draws that as all-green and still
# refuses the merge; actions:status is the only thing we have that names it.
namespace :actions do
    desc "List workflow runs awaiting approval on a PR's or branch's head commit"
    task :pending, [:repo, :target] do |task, args|
        repo, target = actions_scope(args)
        ref = actions_resolve_ref(repo, target)
        pending = actions_runs_for_sha(repo, ref[:sha]).select { |run| actions_awaiting_approval? run }

        info "#{repo} #{actions_describe(ref)} — head #{ref[:sha][0, 8]}"
        if pending.empty?
            info "Nothing awaiting approval."
        else
            pending.each do |run|
                info "  #{run["id"]}  #{run["name"]} (#{run["event"]}, created #{run["created_at"]})"
            end
            info "#{pending.length} run(s) awaiting approval — approve with actions:approve[#{repo},#{target}]"
        end

        stale = actions_stale_pending(repo, ref)
        warning "#{stale} more run(s) on #{ref[:branch]} await approval on older commits — approving those does nothing for the merge" if stale > 0
    end

    desc "Reconcile a PR's required contexts against what its head commit actually reported"
    task :status, [:repo, :target] do |task, args|
        repo, target = actions_scope(args)
        ref = actions_resolve_ref(repo, target)
        error "actions:status needs a PR number, got #{target}" if ref[:number].nil?

        required = actions_required_contexts(repo, ref[:base])
        reported = actions_reported_contexts(repo, ref[:sha])
        missing = required.reject { |context| reported.key? context }
        runs = actions_runs_for_sha(repo, ref[:sha])

        info "#{repo}##{ref[:number]} #{ref[:branch]} → #{ref[:base]}, head #{ref[:sha][0, 8]} (mergeable_state: #{ref[:mergeable_state]})"
        if required.empty?
            warning "#{ref[:base]} has no required status checks in either its rulesets or its branch protection"
        else
            info "Required by #{ref[:base]} (#{required.length}):"
            required.each do |context|
                state = reported[context]
                if state.nil?
                    warning "  MISSING  #{context}"
                else
                    info "  #{state}  #{context}"
                end
            end
        end
        info "Reported on the head commit (#{reported.length}): #{reported.keys.sort.join(", ")}" unless reported.empty?

        if missing.empty?
            info "No required context is missing."
        else
            warning "#{missing.length} required context(s) never reported — the PR reads green and cannot merge:"
            producers = actions_context_producers(repo, ref[:base], missing)
            by_workflow = runs.group_by { |run| run["name"] }
            missing.each do |context|
                workflow = producers[context]
                if workflow.nil?
                    warning "  #{context} — no recently merged PR on #{ref[:base]} shows which workflow emits it"
                    next
                end
                run = (by_workflow[workflow] || []).first
                if run.nil?
                    warning "  #{context} ← workflow \"#{workflow}\", which has no run on this commit at all"
                elsif actions_awaiting_approval? run
                    warning "  #{context} ← workflow \"#{workflow}\", run #{run["id"]} awaiting approval and never executed"
                else
                    warning "  #{context} ← workflow \"#{workflow}\", run #{run["id"]} is #{run["status"]}/#{run["conclusion"]}"
                end
            end
        end

        pending = runs.select { |run| actions_awaiting_approval? run }
        info "#{pending.length} run(s) awaiting approval — actions:approve[#{repo},#{ref[:number]}] would release them" unless pending.empty?
    end

    desc "Approve every workflow run awaiting approval on a PR's or branch's current head commit"
    task :approve, [:repo, :target] do |task, args|
        repo, target = actions_scope(args)
        ref = actions_resolve_ref(repo, target)
        # Head SHA, never the branch: a run parked on a superseded commit can be approved all day
        # and the merge stays blocked.
        runs = actions_runs_for_sha(repo, ref[:sha]).select { |run| actions_awaiting_approval? run }
        if runs.empty?
            info "Nothing awaiting approval on #{repo} #{actions_describe(ref)} (head #{ref[:sha][0, 8]})."
            next
        end

        approved = []
        refused = []
        runs.each do |run|
            out = IO.popen(["gh", "api", "-X", "POST", "repos/#{repo}/actions/runs/#{run["id"]}/approve"], err: [:child, :out], &:read).to_s.strip
            if $?&.success?
                approved << run
                info "Approved #{run["id"]} — #{run["name"]}"
            else
                refused << run
                warning "Could not approve #{run["id"]} — #{run["name"]}: #{out}"
            end
        end
        info "Approved #{approved.length}/#{runs.length} run(s) on #{ref[:sha][0, 8]}"
        warning "#{refused.length} run(s) were refused — see the reasons above" unless refused.empty?
    end

    desc "Re-run only the failed jobs of every failed run on a PR's or branch's head commit"
    task :rerun, [:repo, :target] do |task, args|
        repo, target = actions_scope(args)
        ref = actions_resolve_ref(repo, target)
        runs = actions_runs_for_sha(repo, ref[:sha])
        failed = runs.select { |run| %w(failure timed_out).include? run["conclusion"] }
        unrerunnable = runs.select { |run| %w(startup_failure cancelled).include? run["conclusion"] }

        if failed.empty?
            info "No failed runs on #{repo} #{actions_describe(ref)} (head #{ref[:sha][0, 8]})."
        else
            failed.each do |run|
                # --failed, always: a whole-run rerun burns the jobs that already passed.
                if system("gh", "run", "rerun", run["id"].to_s, "--failed", "--repo", repo)
                    info "Re-ran the failed jobs of #{run["id"]} — #{run["name"]}"
                else
                    warning "Could not re-run #{run["id"]} — #{run["name"]}"
                end
            end
        end
        unrerunnable.each do |run|
            warning "Skipped #{run["id"]} — #{run["name"]} concluded #{run["conclusion"]}, which has no failed jobs to re-run"
        end
    end

    def actions_scope(args)
        first = args[:repo].to_s.strip
        second = args[:target].to_s.strip
        error "Usage: actions:<verb>[<owner/repo>,<pr-or-branch>] or actions:<verb>[<pr-or-branch>]" if first.empty?
        return [first, second] unless second.empty?
        [actions_cwd_repo, first]
    end

    def actions_cwd_repo
        error "No owner/repo given and #{Dir.pwd} is not a git repository" unless Git.is_repo? Dir.pwd
        repo = Git.repo_name_with_org
        error "Could not read owner/repo from the git remote in #{Dir.pwd}" unless repo.to_s.include? "/"
        repo
    end

    def actions_resolve_ref(repo, target)
        if target.match? /\A\d+\z/
            pr = actions_gh_json "repos/#{repo}/pulls/#{target}"
            { number: pr["number"], branch: pr.dig("head", "ref"), sha: pr.dig("head", "sha"),
              base: pr.dig("base", "ref"), mergeable_state: pr["mergeable_state"] }
        else
            branch = actions_gh_json "repos/#{repo}/branches/#{target}"
            { number: nil, branch: target, sha: branch.dig("commit", "sha"), base: nil, mergeable_state: nil }
        end
    end

    def actions_describe(ref)
        ref[:number].nil? ? "branch #{ref[:branch]}" : "##{ref[:number]} (#{ref[:branch]})"
    end

    def actions_gh_json(path, soft: false)
        out = IO.popen(["gh", "api", path], err: [:child, :out], &:read).to_s
        unless $?&.success?
            return nil if soft
            error "gh api #{path} failed: #{out.strip}"
        end
        begin
            JSON.parse out
        rescue JSON::ParserError
            return nil if soft
            error "gh api #{path} returned something that is not JSON: #{out.strip[0, 200]}"
        end
    end

    def actions_runs_for_sha(repo, sha)
        res = actions_gh_json "repos/#{repo}/actions/runs?head_sha=#{sha}&per_page=100"
        runs = res["workflow_runs"] || []
        warning "#{sha[0, 8]} has #{res["total_count"]} runs; only the first #{runs.length} were read" if res["total_count"].to_i > runs.length
        runs
    end

    def actions_awaiting_approval?(run)
        run["conclusion"] == "action_required" || %w(waiting action_required).include?(run["status"])
    end

    def actions_stale_pending(repo, ref)
        return 0 if ref[:branch].to_s.empty?
        res = actions_gh_json("repos/#{repo}/actions/runs?branch=#{CGI.escape ref[:branch]}&per_page=100", soft: true)
        return 0 if res.nil?
        (res["workflow_runs"] || []).count { |run| actions_awaiting_approval?(run) && run["head_sha"] != ref[:sha] }
    end

    def actions_required_contexts(repo, base)
        # Rulesets first — cubecraft 404s on /branches/production/protection and keeps the real
        # answer in a ruleset.
        rules = actions_gh_json("repos/#{repo}/rules/branches/#{base}", soft: true) || []
        contexts = rules.select { |rule| rule["type"] == "required_status_checks" }
                        .flat_map { |rule| rule.dig("parameters", "required_status_checks") || [] }
                        .map { |check| check["context"] }
                        .uniq
        return contexts unless contexts.empty?

        legacy = actions_gh_json("repos/#{repo}/branches/#{base}/protection/required_status_checks", soft: true)
        (legacy&.dig("contexts") || []).uniq
    end

    def actions_reported_contexts(repo, sha)
        reported = {}
        checks = actions_gh_json "repos/#{repo}/commits/#{sha}/check-runs?per_page=100"
        runs = checks["check_runs"] || []
        warning "#{sha[0, 8]} has #{checks["total_count"]} check runs; only the first #{runs.length} were read" if checks["total_count"].to_i > runs.length
        runs.each { |check| reported[check["name"]] = check["conclusion"] || check["status"] }

        combined = actions_gh_json("repos/#{repo}/commits/#{sha}/status", soft: true)
        (combined&.dig("statuses") || []).each { |status| reported[status["context"]] ||= status["state"] }
        reported
    end

    # A required context does not name its workflow — "Build CubeCraft / Gradle Run" comes out of the
    # "Validate PR" workflow. Join check runs to runs through the check suite on a PR that actually
    # finished, rather than guessing from the names.
    def actions_context_producers(repo, base, contexts, samples: 5)
        wanted = contexts.dup
        found = {}
        merged = (actions_gh_json("repos/#{repo}/pulls?state=closed&base=#{CGI.escape base}&per_page=30", soft: true) || [])
                 .select { |pr| pr["merged_at"] }
                 .first(samples)
        merged.each do |pr|
            break if wanted.empty?
            sha = pr.dig "head", "sha"
            next if sha.nil?
            suites = {}
            actions_runs_for_sha(repo, sha).each { |run| suites[run["check_suite_id"]] ||= run["name"] }
            checks = actions_gh_json("repos/#{repo}/commits/#{sha}/check-runs?per_page=100", soft: true)
            (checks&.dig("check_runs") || []).each do |check|
                next unless wanted.include? check["name"]
                workflow = suites[check.dig("check_suite", "id")]
                next if workflow.nil?
                found[check["name"]] = workflow
                wanted.delete check["name"]
            end
        end
        found
    end
end
