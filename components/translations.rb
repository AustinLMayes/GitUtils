require "json"

# Never prs:submit these. It pushes `translations`, a bot-owned teamziax branch, and its
# `gh pr edit` renames the PR to the bot's commit subject and blanks the body.
namespace :translations do
    desc "Approve parked Actions runs on bot Translations Update PRs, and put each on the train with dev reviewers"
    task :sweep do
        prs = translations_bot_prs
        info "#{prs.length} open bot Translations Update PR(s)"
        failed = prs.reject { |repo, number| translations_sweep_pr(repo, number) }
        error "Not finished on #{failed.map { |repo, number| "#{repo}##{number}" }.join(", ")} — see above" unless failed.empty?
    end

    def translations_bot_prs
        result = GitHub.gh("search", "prs", "--owner", "teamziax", "--state", "open", "Translations Update in:title",
                           "--limit", "50", "--json", "number,repository,author", stderr: :merge, fail_open: false)
        error "gh search prs failed: #{result.out.strip}" unless result.ok?
        # type, not login: the login is `github-actions[bot]` and an equality on anything else matches nothing.
        JSON.parse(result.out)
            .select { |pr| pr.dig("author", "type") == "Bot" }
            .map { |pr| [pr.dig("repository", "nameWithOwner"), pr["number"].to_s] }
    end

    def translations_sweep_pr(repo, number)
        ref = actions_resolve_ref(repo, number)
        pending = actions_runs_for_sha(repo, ref[:sha]).count { |run| actions_awaiting_approval? run }
        info "#{repo}##{number} #{ref[:branch]} head #{ref[:sha][0, 8]} mergeable_state=#{ref[:mergeable_state]} pending_runs=#{pending}"
        if pending > 0
            %w(actions:status actions:approve).each do |name|
                Rake::Task[name].reenable
                Rake::Task[name].invoke(repo, number)
            end
        end

        entry = translations_train_entry(repo, number)
        return false if entry == :error
        if entry.nil?
            return false unless train("pr", "add", ref[:branch], repo, number) == true
            reviewers = []
        else
            reviewers = Array(entry["intendedReviewers"])
            info "#{repo}##{number} is already on the train"
        end
        return true unless reviewers.empty?

        train("pr", "assign", repo, number, *Reviewers.expand_all(["dev"], org: repo.split("/").first)) == true
    end

    def translations_train_entry(repo, number)
        result = Ax.call("pr", "show", repo, number, fail_open: false, stderr: :merge)
        return JSON.parse(result.out) if result.ok?
        return nil if result.out.include?("is not in any train")

        warning "Could not read #{repo}##{number} from the train: #{result.out.strip}"
        :error
    rescue JSON::ParserError
        warning "`ax pr show #{repo} #{number}` did not answer JSON"
        :error
    end
end
