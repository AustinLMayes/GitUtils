require_relative "../../RandomScripts/jira"

namespace :jira do
    def extract_jira_issues(message)
        message.scan(/CC-\d+/)
      end
      
      def transition_issues(sha, comment = nil)
        message = `git log --format=%B -n 1 #{sha}`.strip.split("\n").first
        jiras = extract_jira_issues(message)
        jiras.each do |jira|
          testing_id = -1
          done_id = -1
          status = Jira::Issues.get(jira)["fields"]['status']['name']
          next if status == "Done" || status == "Testing"
          Jira::Issues.transitions(jira)["transitions"].each do |transition|
            next unless transition["isAvailable"] == true
            if transition["name"] == "Testing"
              testing_id = transition["id"]
            elsif transition["name"] == "Done"
              done_id = transition["id"]
            end
          end
          id_to_use = testing_id
          id_to_use = done_id if id_to_use == -1
          if id_to_use == -1
            warning "No transition found for #{jira}"
          end
          Jira::Issues.transition(jira, id_to_use)
          Jira::Issues.assign(jira)
          Jira::Issues.add_to_current_sprint(jira, Jira::CC::BOARD_ID)
          recent_comment = TempStorage.is_stored?(jira + "-comment")
          if comment && !recent_comment
            Jira::Issues.add_comment(jira, comment) 
            TempStorage.store(jira + "-comment", "true", expiry: 20.minutes)
          end
          info "Transitioned #{jira}"
          wait_range 5, 10
        end
        jiras
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
end
