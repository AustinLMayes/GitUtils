module Ansi
    extend self

    COLORS = [:black, :red, :green, :yellow, :blue, :purple, :aqua]

    def color(code, text = nil)
        if text
            "#{color(code)}#{text}#{reset}"
        else
            "\e[#{code}m"
        end
    end

    def reset
        color(0)
    end

    COLORS.each_with_index do |name, code|
        define_method name do |text = nil|
            color(30 + code, text)
        end
    end
end

def info(msg)
    puts "#{Ansi.green "[INFO]"} #{msg}"
end

def warning(msg)
    puts "#{Ansi.yellow "[WARNING]"} #{msg}"
end

def error(msg)
    puts "#{Ansi.red "[ERROR]"} #{msg}"
    exit false
end

def fix_path(path)
  if path.start_with? "~"
    path = "#{Dir.home}/#{path[1..-1]}"
  end
  path
end

def wait_range(min, max)
  min = min.to_i if min.is_a? String
  max = max.to_i if max.is_a? String

  return if max < 1
  min *= 2 if $extra_slow
  max *= 2 if $extra_slow

  random = rand(min..max)
  info "Sleeping for #{random} seconds"
  sleep random
end

module GitHub
  extend self

  def make_pr(title, body: " ", base: nil, suffix: nil)
    is_mco = Git.current_branch.end_with?("mco")
    base = is_mco ? "production-mco" : "production" unless base
    suffix = is_mco ? "[MCO]" : "[Java]" unless suffix
    info "Making PR based off of #{base} with title \"#{title} #{suffix}\" and body \"#{body}\""
    `gh pr create --title "#{title} #{suffix}" --body "#{body}" --base #{base}`
  end
end

module Git
  extend self

  def ensure_git(where)
    error "Repo not found at path #{where}!" unless File.exists? where
    error "#{where} is not a Git directory!" unless File.exists? "#{where}/.git"
  end

  def checkout_branch(branch)
    system "git", "checkout", branch
    Git.ensure_branch branch
    system "git branch --set-upstream-to=origin/#{branch} #{branch}"
    system "git pull"
  end

  def current_branch
    `git branch --show-current`.strip
  end

  def ensure_branch(branch)
    error "Not on expected branch #{branch}! On #{current_branch}" if current_branch.downcase != branch.downcase
  end

  def delete_branches(*branches, remote: true)
    info "Deleting #{branches.join(" ")}..."
    branches.shuffle.each do |branch|
      system "git branch -D #{branch}"
      system "git push origin --delete #{branch}" if remote
      wait_range 3, 6
    end
  end

  def pull_branches(*branches, ensure_exists: true, delay: [0, 0])
    act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
      info "Pulling #{branch}"
      system "git", "pull"
    end
  end

  def push_branches(*branches, ensure_exists: true, delay: [0, 0])
    act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
      info "Pushing #{branch}"
      system "git", "pu"
    end
  end

  def act_on_branches(*branches, ensure_exists: true, delay: [0, 0], shuffle: true, &block)
    existing = []
    branches.each do |branch|
      existing << branch

      # if system "git rev-parse --verify #{branch}"
      #   existing << branch
      # elsif ensure_exists
      #   error "Branch #{branch} does not exist in repository!"
      # else
      #   warning "Tried to check out #{branch} but it didn't exist!"
      # end
    end

    branches = branches.shuffle if shuffle

    existing.each do |branch|
      info "Checking out #{branch}..."
      system "git", "checkout", branch
      if current_branch.downcase == branch.downcase
        wait_range *delay
        block.call branch
      end
    end
  end

  def ensure_exists(branch)
    error "Branch #{branch} does not exist in repository!" unless branch_exists branch
  end

  def branch_exists(branch)
    system "git rev-parse --verify #{branch}"
  end
end

module AppleScript
  extend self

  def run_script(script)
    system 'osascript', *script.split(/\n/).map { |line| ['-e', line] }.flatten
  end
end

module Slack
  extend self

  def send_message(channel, message, workspace = "CubeCraft Games")
    AppleScript.run_script(
      "tell script \"Slack\"
        	send message \"#{message.downcase}\" in channel \"#{channel}\" in workspace \"#{workspace}\"
       end tell"
    )
  end

end
