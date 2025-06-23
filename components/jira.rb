require_relative "../../RandomScripts/jira"

namespace :jira do
    def extract_jira_issues(message)
      message.scan(/CC-\d+/)
    end
    
    PASSED_QA = "10056"

    def transition_issues(sha, comment: nil, done: false, ensure_mine: false)
      message = `git log --format=%B -n 1 #{sha}`.strip.split("\n").first
      jiras = extract_jira_issues(message)
      transitioned = []
      jiras.each do |jira|
        trans_testing = nil
        trans_done = nil
        fields = Jira::Issues.get(jira)["fields"]
        if ensure_mine
          if fields['assignee'].nil? || fields['assignee']['emailAddress'] != "austin@ziax.com"
            warning "Skipping #{jira} as it is not assigned to me (#{fields['assignee']})"
            next
          end
        end
        id = fields['status']['id']
        status = fields['status']['name']
        next if status == "Done" || (!done && (status == "Testing" || id == PASSED_QA)) || status == "Completed"
        Jira::Issues.transitions(jira)["transitions"].each do |transition|
          next unless transition["isAvailable"] == true
          if transition["name"] == "Testing"
            trans_testing = transition
          elsif transition["name"] == "Done" || transition["name"] == "Completed"
            trans_done = transition
          end
        end
        done = done && (id == PASSED_QA || status == "Testing Failed")
        trans_to_use = done ? trans_done : trans_testing
        trans_to_use = trans_done if trans_testing.nil? && !done
        unless trans_to_use
          warning "No transition found for #{jira}"
          next
        end
        if fields['status']['id'] != trans_to_use['to']['id']
          Jira::Issues.transition(jira, trans_to_use['id'])
        end
        Jira::Issues.add_to_current_sprint(jira, Jira::CC::BOARD_ID)
        recent_comment = TempStorage.is_stored?(jira + "-comment")
        if comment && !recent_comment
          Jira::Issues.add_comment(jira, comment)
          TempStorage.store(jira + "-comment", "true", expiry: 20.minutes)
        end
        info "Transitioned #{jira}"
        transitioned << jira
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
      commits = Git.last_n_commits(10)
      commits.each do |commit|
        transition_issues(commit, done: true, ensure_mine: true)
      end
      system "git checkout #{current}"
      system "git stash pop"
    end
end
