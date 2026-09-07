require 'common'
require "json"
require 'active_support/time'

# GUTILS_NO_TRAIN=true makes every PRTrain call in this repo a no-op, without touching
# the call sites. The unattended bug-run sets it: that run creates branches and PRs but
# must never register them with the train, because train registration is what moves
# Linear to a testing state — and it was doing that for commits it never pushed.
class SuppressedTrain
  def if_connectable
    warning "GUTILS_NO_TRAIN=true — skipping PRTrain call"
    nil
  end

  def is_connectable? = false
end

TRAIN =
  if ENV["GUTILS_NO_TRAIN"] == "true"
    SuppressedTrain.new
  else
    ExternalServer.new("localhost", 4567)
  end

def determine_dev_branch
  if Git.branch_exists "master"
    "master"
  else
    "main"
  end
end

desc "Wait between x and x seconds"
task :wait do |task, args|
  wait_range *args.extras
end

desc "Run prereqs"
task :before do |task, args|
  Git.ensure_git Dir.pwd
  @current = Git.current_branch
  unless ENV["GUTILS_DO_DELAY"]
    info "Delay variable not set! Use delays (y/n)"
    input = STDIN.gets.strip.downcase
    input = "y" unless input
  end
  $delays_enabled = ENV["GUTILS_DO_DELAY"] == "true"
  info ($delays_enabled ? "" : "NOT ") + "Using Delays!"
  $extra_slow = ENV["GUTILS_EXTRA_SLOW"] == "true"
  info "Using double delay times" if $extra_slow
  $dev_branch = determine_dev_branch
  $dont_push = ENV["GUTILS_DONT_PUSH"] == "true"
end

def get_non_stacked_branches(args)
  branches = [Git.current_branch]
  if args.extras.length > 0
    if args.extras[0] == "all" && args.extras[1].nil?
      branches = Git.find_branches("^austin\\/(?![su]\\/).*")
    else
      branches = Git.find_branches_multi(args.extras)
    end
  end
  branches
end

Dir["#{File.dirname(__FILE__)}/components/*.rb"].each { |file| load file }


