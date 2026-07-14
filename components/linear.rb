namespace :linear do
    def extract_issue_ids(message)
      message.scan(/(?:CCENG|ROC)-\d+/)
    end

    IN_QA_STATES = ["QA Pending", "QA In Progress", "QA Passed"].freeze

    def transition_issues(sha, comment: nil, done: false, ensure_mine: false)
      message_full = Git.commit_message(sha)
      message = message_full.values.join(" ")
      if message.start_with?("Merge pull request")
        pr_number = message.split(" ")[3].gsub("#", "")
        message = `gh api repos/#{Git.repo_name_with_org}/pulls/#{pr_number} --jq '.title + \"\\n\" + .body'`.strip
      end
      ids = extract_issue_ids(message)
      transitioned = []
      ids.each do |id|
        issue = Linear::Issues.get(id)
        if issue.nil?
          warning "Skipping #{id} - not found in Linear"
          next
        end
        if ensure_mine
          email = issue.dig("assignee", "email")
          if email != "austin@ziax.com"
            warning "Skipping #{id} as it is not assigned to me (#{email.inspect})"
            next
          end
        end
        status = issue.dig("state", "name")
        if status == "Done"
          info "Skipping #{id} as it is already #{status}."
          next
        end
        if done
          target = status == "QA Passed" ? "Done" : "QA Pending"
        else
          if IN_QA_STATES.include?(status)
            info "Skipping #{id} as it is already #{status}."
            next
          end
          target = "QA Pending"
        end
        Linear::Issues.set_state(id, target)
        Linear::Issues.add_to_current_cycle(id)
        recent_comment = TempStorage.is_stored?(id + "-comment")
        if comment && !recent_comment
          Linear::Issues.add_comment(id, comment)
          TempStorage.store(id + "-comment", "true", expiry: 20.minutes)
        end
        info "Transitioned #{id} -> #{target}"
        transitioned << id
        wait_range 5, 10
      end
      transitioned
    end

    def generate_qa_message(keys)
      use_please = [true, false].sample
      use_tag = [true, false].sample
      intros = ["Can someone", "Can anyone", "Is anyone able to", "Can I get someone to", "Can I get anyone to"]
      segs = ["have a look at", "check out", "take a look at", "review", "check", "have a look over"]
      intro = intros.sample
      seg = segs.sample
      message = ""
      message += "@qateam " if use_tag
      message += "#{intro} "
      message += "#{seg} "
      i = 0
      keys.each do |key|
        message += key
        if i < keys.length - 1
          message += ", " if i < keys.length - 2
          message += " and " if i == keys.length - 2
        end
        i += 1
      end
      message += " please?" if use_please
      message
    end

    desc "Transition the issues for unpushed commits"
    task transition_issues: :before do |task, args|
      commits = Git.commits_after_last_push
      if args.extras.length > 0
        commits = Git.last_n_commits(args.extras[0].to_i)
      end
      ids = []
      commits.each do |commit|
        ids += transition_issues(commit)
      end
      Clipboard.copy(generate_qa_message(ids))
    end

    desc "Transition the issues on production to Done"
    task transition_prod: :before do |task, args|
      current = Git.current_branch
      system "git stash"
      system "git checkout production"
      Git.ensure_branch "production"
      commits = Git.last_n_commits(30)
      commits.each do |commit|
        transition_issues(commit, done: true, ensure_mine: true)
      end
      system "git checkout #{current}"
      system "git stash pop"
    end
end
