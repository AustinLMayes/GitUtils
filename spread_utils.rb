require 'common'
require 'active_support/time'

desc "Spread out all unpushed commits over a given time period"
task :spread_unpushed do |task, args|
  time = args.extras[0].to_i.hours
  dirs = []
  dirs << Dir.pwd if args.extras[2].nil?
  dirs += args.extras[2..-1] unless args.extras[2].nil?
  offset = 0
  offset = args.extras[1].to_i.hours unless args.extras[2].nil?
  data = gather_commits(dirs)
  spread(data, time, Time.now - offset - time)
end

desc "Reset repos to the latest commit from remote"
task :reset do |task, args|
  dirs = []
  dirs << Dir.pwd if args.extras[0].nil?
  dirs += args.extras[0..-1] unless args.extras[0].nil?
  dirs = fix_relative_dirs dirs
  dirs.each do |dir|
    Dir.chdir(dir) do
      system "git", "fetch", "--all"
      system "git", "add", "."
      system "git", "reset", "--hard", "origin/#{Git.current_branch}"
    end
  end
end

desc "Spread out all commits from today"
task :spread_today do |task, args|
  dirs = []
  dirs << Dir.pwd if args.extras[0].nil?
  dirs += args.extras[0..-1] unless args.extras[0].nil?
  dirs = fix_relative_dirs dirs
  time = 1.minute
  start = (Time.now.hour < 4 ? Time.now - 1.day : Time.now).to_date.to_time + rand(8..11).hours + rand(0..60).minutes + rand(0..60).seconds
  data = gather_commits(dirs, start)
  commits = data.length
  multiplier = commits > 20 ? 0.08 : 0.15
  data.reverse.each do |d|
    sha = d[:sha]
    Dir.chdir(d[:dir]) do
      changes = Git.lines_changed sha
      changes *= rand(0.08..1).ceil if commits > 20
      add = (changes.to_f / 7.to_f).ceil
      add += (changes * multiplier).ceil if changes > 75
      add += rand(2..6).minutes # Deploy time
      time += add.minutes
    end
  end
  min = Git.last_pushed_date
  start += (start.to_date.to_time + 8.hours) - start unless start.hour > 8
  while time / (60 * 60) > 10
    time -= time * rand(0.01..0.07)
  end
  max = Time.now
  while max > min + 30.seconds && max.hour > 17
    max -= 26.seconds
  end
  while true
    base_under_min = min > start
    start_over_max = start > max
    total_over_max = start + time > max
    raise "Base both above and below min" if base_under_min && start_over_max
    if !base_under_min && !start_over_max && !total_over_max
      break
    end
    if base_under_min
      start += 1.seconds
    elsif start_over_max
      start -= 1.seconds
    elsif total_over_max
      time -= 1.seconds
    end
  end
  spread(data, time, start)
end

def fix_relative_dirs(dirs)
  if dirs == ["a"]
    # Treat glob as parent path starting at "Ziax"
    # Walk up Dir.pwd until we find "Ziax*" and set that as the base, then find all dirs with a .git folder
    dirs = []
    Dir.chdir(Dir.pwd) do
      while !Dir.pwd.split("/").last.start_with?("Ziax") && Dir.pwd != "/"
        Dir.chdir("..")
      end
      base = Dir.pwd
      Dir.glob("**/**/.git").each do |dir|
        next if dir.include?("/work/") # Spigot
        dirs << base + "/" + File.dirname(dir)
      end
    end
  end
  dirs.map do |dir|
    if dir.start_with?(".")
      dir = File.expand_path(dir)
    end
    if dir.start_with?("~")
      dir = File.expand_path(dir)
    end
    Git.ensure_git dir
    dir
  end
end

def gather_commits(dirs, beg=nil)
  dirs = fix_relative_dirs(dirs)
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
      Dir.chdir(dir) do
        coms = beg == nil ? Git.commits_after_last_push_with_date : Git.commits_after_with_date(beg)
        data << coms.map do |c|
          sha = c[:sha]
          date = c[:date]
          puts sha
          puts date
          changes = Git.lines_changed sha
          {sha: sha, lines: changes, dir: dir, date: date}
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

# commits = [{sha: "1234567", lines: 100, dir: "some-git-dir"}, ...]
def spread(commits, spread, start_at)
  seconds = spread % 60
  minutes = (spread / 60) % 60
  hours = spread / (60 * 60)
  info "Spreading out #{commits.length} commit(s) across #{format("%02d:%02d:%02d", hours, minutes, seconds)} starting at #{start_at.strftime("%I:%M %p")}"
  total = commits.sum { |c| c[:lines] }
  commits.each do |c|
    c[:offset] = ((c[:lines].to_f/total.to_f) * spread).round
  end
  commit_at = start_at
  conditions_by_dir = {}
  commits.reverse.each do |c|
    commit_at += c[:offset]
    friendly_dir = c[:dir].split("/").last
    info "#{c[:sha][0..6]} from #{friendly_dir} will be committed at #{commit_at.strftime("%I:%M:%S %p")}"
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
      system "FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter '#{joined}' HEAD~#{back}..HEAD"
    end
    info "Spread out commits for #{dir}"
  end
  info "Spread out commits"
end