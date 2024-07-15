require 'common'
require 'active_support/time'

desc "Spread out all unpushed commits over a given time period"
task :spread_unpushed do |task, args|
    time = TimeUtils.parse_time(args.extras[0])
    dirs = FileUtils.parse_args(args, 2)
    offset = 0
    offset = TimeUtils.parse_time(args.extras[1]) unless args.extras[1].nil?
    start_at = Time.now - time
    start_at = Git.last_pushed_date if Git.is_repo?(Dir.pwd) && start_at < Git.last_pushed_date
    data = gather_commits(dirs, start_at - offset)
    warning "Start time (#{start_at}) is before last pushed date (#{Git.last_pushed_date})" if Git.is_repo?(Dir.pwd) && start_at < Git.last_pushed_date
    spread(data, start_at, Time.now)
end

desc "Reset repos to the latest commit from remote"
task :reset do |task, args|
  dirs = FileUtils.parse_args(args, 0)
  dirs.each do |dir|
    Dir.chdir(dir) do
      system "git", "fetch", "--all"
      system "git", "add", "."
      system "git", "reset", "--hard", "origin/#{Git.current_branch}"
    end
  end
end

PUSH_ORDER = [
    "BotsBootstrap", "SentinelService",
    "AnticheatBot", "CubeBot", "LeaderboardBot", "NetworkControl", "NickService", "PurchaseProcessor", "ScheduledServicesBot", "StaffChatSlackBridgeBot", "Steve", "VoteBot", "WebsiteRegisterBot", "QueueBot"
]

desc "Push all repos in order, waiting for each to finish building before pushing the next"
task :push do |task, args|
    dirs = FileUtils.parse_args(args, 0, 0)
    sorted = []
    if args.extras[1].nil?
        PUSH_ORDER.each do |dir|
            sorted << dir if dirs.include?(dir)
            dirs.delete(dir)
        end
        dir_string = dirs.map { |dir| dir.split("/").last }.join(", ")
        error "Directories: #{dir_string} not found in push order" if dirs.count > 0
    else
        sorted = dirs
        sorted.delete_if { |dir| !args.extras[1..-1].include?(dir.split("/").last) }
        sorted.sort_by! { |dir| args.extras[1..-1].index(dir.split("/").last) }
    end
    sorted.each do |dir|
        Dir.chdir(dir) do
            info "Pushing #{dir}"
            next unless Git.push
            branch = Git.current_branch
            repo = Git.repo_name
            org = Git.repo_org
            sleep 20
            runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
            raise "Run failed" unless system "gh run watch #{runner_id} --repo=#{org}/#{repo} --exit-status"
        end
    end
end

desc "Push all repos in order, waiting for each to finish building before pushing the next"
task :push_run do |task, args|
    dirs = FileUtils.parse_args(args, 0)
    sorted = []
    PUSH_ORDER.each do |dir|
        sorted << dir if dirs.include?(dir)
        dirs.delete(dir)
    end
    dir_string = dirs.map { |dir| dir.split("/").last }.join(", ")
    error "Directories: #{dir_string} not found in push order" if dirs.count > 0
    sorted.each do |dir|
        Dir.chdir(dir) do
            info "Pushing #{dir}"
            branch = Git.current_branch
            repo = Git.repo_name
            org = Git.repo_org
            if Git.push
                sleep 20
                runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
                raise "Run failed" unless system "gh run watch #{runner_id} --repo=#{org}/#{repo} --exit-status"
            else
                runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
                if system "gh run rerun #{runner_id} --repo=#{org}/#{repo}"
                    sleep 20
                    runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
                    raise "Run failed" unless system "gh run watch #{runner_id} --repo=#{org}/#{repo} --exit-status"
                end
            end
        end
    end
end

desc "Rerun failed jobs for a set of repos, waiting for each to finish in order"
task :rerun do |task, args|
    dirs = FileUtils.parse_args(args, 0)
    sorted = []
    PUSH_ORDER.each do |dir|
        sorted << dir if dirs.include?(dir)
        dirs.delete(dir)
    end
    dir_string = dirs.map { |dir| dir.split("/").last }.join(", ")
    error "Directories: #{dir_string} not found in push order" if dirs.count > 0
    sorted.each do |dir|
        Dir.chdir(dir) do
            info "Pushing #{dir}"
            branch = Git.current_branch
            repo = Git.repo_name
            org = Git.repo_org
            runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
            if system "gh run rerun #{runner_id} --failed --repo=#{org}/#{repo}"
                sleep 20
                runner_id = JSON.parse(`gh run list -L 1 --json databaseId -b #{branch} --repo=#{org}/#{repo}`)[0]['databaseId']
                raise "Run failed" unless system "gh run watch #{runner_id} --repo=#{org}/#{repo} --exit-status"
            end
        end
    end
end

desc "Push all repos in order"
task :fpush do |task, args|
    dirs = FileUtils.parse_args(args, 0)
    sorted = []
    PUSH_ORDER.each do |dir|
        sorted << dir if dirs.include?(dir)
        dirs.delete(dir)
    end
    dir_string = dirs.map { |dir| dir.split("/").last }.join(", ")
    error "Directories: #{dir_string} not found in push order" if dirs.count > 0
    sorted.each do |dir|
        Dir.chdir(dir) do
            info "Pushing #{dir}"
            Git.push
        end
    end
end

def gather_commits(dirs, beg=nil)
  dirs = FileUtils.fix_relative_dirs(dirs)
  count_by_dir = {}
  dirs_index = 0
  data = []
  info "Gathering commits from #{dirs.join(", ")}"
  # Return if no directories
  return data if dirs.count == 0
  if dirs.count == 1
    Dir.chdir(dirs[0]) do
      coms = beg == nil ? Git.commits_after_last_push : Git.commits_after(beg)
      coms.each do |sha|
        changes = Git.lines_changed sha
        data << {sha: sha, lines: changes, dir: dirs[0]}
      end
    end
  else
    dirs.each do |dir|
      puts "Checking #{dir}"
      next unless Git.is_repo? dir
      Dir.chdir(dir) do
        coms = beg == nil ? Git.commits_after_last_push_with_date : Git.commits_after_with_date(beg)
        data << coms.map do |c|
          sha = c[:sha]
          date = c[:date]
          message = c[:message]
          changes = Git.lines_changed sha
          {sha: sha, lines: random_num(changes), dir: dir, date: date, message: message}
        end
      end
    end
    data = data.flatten
    # Sort by date
    data.sort_by! { |d| d[:date] }
  end
  # Print commit count by dir
  data_by_dir = data.group_by { |d| d[:dir] }
  data_by_dir.each do |dir, data|
    info "Found #{data.count} commit(s) in #{dir}"
  end
  data
end

def random_num(base)
    min = (base * 0.1).ceil
    sign = rand(5) == 0 ? -1 : 1
    change = sign.to_f * rand(0.1..3.4)
    [min, (base + (base * change)).ceil].max
end

# commits = [{sha: "1234567", lines: 100, dir: "some-git-dir"}, ...]
def spread(commits, start_at, end_at=Time.now)
    puts "Last Pushed Date: " + Git.last_pushed_date.to_s
    end_at = Time.now if end_at > Time.now
    spread = end_at - start_at
    seconds = spread % 60
    minutes = (spread / 60) % 60
    hours = (spread / 60 / 60) % 24
    days = end_at.to_date.mjd - start_at.to_date.mjd
    info "Spreading out #{commits.length} commit(s) across #{format("%02dd %02dh %02dm %02ds", days, hours, minutes, seconds)} starting at #{start_at.strftime("%m/%d/%Y %H:%M:%S")} and ending at #{end_at.strftime("%m/%d/%Y %H:%M:%S")}"
    if days < 2
        total = commits.sum { |c| c[:lines] }
        commit_at = start_at
        first = true
        commits.each do |c|
            commit_at += (c[:lines].to_f / total) * spread unless first
            c[:commit_at] = commit_at
            first = false
        end
    else
        total_lines = commits.sum { |c| c[:lines] }
        lines_per_day = total_lines / days
        # Split commits into days
        commits_by_day = [[]]
        lines = 0
        commits.each do |c|
            if lines + c[:lines] > lines_per_day && commits_by_day.last.count > 0 && commits_by_day.count < days
                commits_by_day << []
                lines = 0
            end
            commits_by_day.last << c
            lines += c[:lines]
        end
        commits = []
        # Spread out commits by day
        offset = 0
        day_start = start_at
        long_day = false
        commits_by_day.each do |day|
            begin
                day_end = day_start + (60 * 60 * rand(5..9))
                day_end += 60 * 60 * rand(0..3) if long_day
                while day_end.hour > 19 && !long_day
                    day_end -= 60 * 60
                end
                while day_end.day > day_start.day
                    day_end -= 60 * 60
                end
                day_end = [day_end, end_at].min
                info "Day #{commits_by_day.index(day) + 1} will start at #{day_start.strftime("%m/%d/%Y %I:%M %p")} and end at #{day_end.strftime("%m/%d/%Y %I:%M %p")}"
                error "Day is too short" if day_end - day_start == 0
                total = day.sum { |c| c[:lines] }
                cur_time = day_start
                spread = day_end - day_start
                day.each do |c|
                    commit_offset = ((c[:lines].to_f/total.to_f) * spread).round
                    cur_time += commit_offset
                    commit_time = cur_time
                    if commit_time > day_end
                        warning "Commit #{c[:sha]} is too late for day #{commits_by_day.index(day) + 1} (#{commit_time.strftime("%m/%d/%Y %I:%M %p")})"
                        # If out of days, pull back time of current day
                        if commits_by_day.index(day) == commits_by_day.length - 1
                            warning "Pulling back time of current day"
                            new_start = day_start - 60 * 60
                            # Make sure we don't go back too far
                            if new_start < day_start.midnight
                                c[:commit_at] = day_end
                            else
                                day_start = new_start
                                long_day = true
                                raise "Out of days"
                            end
                        else
                            warning "Moving to next day"
                            # Otherwise, move to next day
                            day.delete c
                            # Update next day and loop
                            commits_by_day[commits_by_day.index(day) + 1].unshift c
                        end
                    else
                        c[:commit_at] = commit_time
                    end
                end
            rescue Exception => e
                if e.message == "Out of days"
                    retry
                else
                    raise e
                end
            end
            day_start = day_start.midnight + (60 * 60 * 24)
            day_start += (rand(8..11).hours + rand(1..55).minutes) + (rand(1..55).seconds)
            day_start = [day_start, end_at].min
            long_day = false
        end
        commits = commits_by_day.flatten
    end
    conditions_by_dir = {}
    commits.each do |c|
        commit_at = c[:commit_at]
        friendly_dir = c[:dir].split("/").last
        info "#{c[:sha][0..6]} (#{c[:message]}) from #{friendly_dir} will be committed at #{commit_at.strftime("%m/%d/%Y %I:%M:%S %p")}"
        conditions_by_dir[c[:dir]] ||= []
        conditions_by_dir[c[:dir]] << ["\nif [ $GIT_COMMIT = #{c[:sha]} ]
        then
            export GIT_AUTHOR_DATE=\"#{commit_at}\"
            export GIT_COMMITTER_DATE=\"#{commit_at}\"
        fi"]
    end
    conditions_by_dir.each do |dir, conditions|
        info "Setting dates for #{dir}"
        Dir.chdir(dir) do
            joined = conditions.join("")
            back = conditions.count
            # Also re-sign commits
            system "FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '#{joined}' --commit-filter 'git commit-tree -S \"$@\";' HEAD~#{back}..HEAD"
        end
        info "Spread out commits for #{dir}"
    end
    info "Spread out commits"
end