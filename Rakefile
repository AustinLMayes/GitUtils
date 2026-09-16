require 'common'
require "json"
require 'active_support/time'

# GUTILS_NO_TRAIN=true makes every PRTrain call in this repo a no-op, without touching
# the call sites. The unattended bug-run sets it: that run creates branches and PRs but
# must never register them with the train, because train registration is what moves
# Linear to a testing state — and it was doing that for commits it never pushed.
TRAIN_ENABLED = ENV["GUTILS_NO_TRAIN"] != "true"

# 🔴 `ax`, not a socket. These used to POST to localhost:4567 through `ExternalServer#send_request`,
# which answers true/false — so a task could loop over ten PRs, have every one refused, and print
# ten successes. `ax` reads the daemon's receipt and says what actually moved.
#
# Three outcomes, not two, because a caller in a loop needs to tell them apart:
#   true   — it did something, and `out` says what
#   false  — the train ACCEPTED the command and nothing changed, or refused it; this PR only
#   :down  — the daemon is not running, so every remaining PR in this loop will fail the same way
AX_TRAIN_DOWN = 3
AX_TRAIN_NO_CHANGE = 4

def train(*args)
  argv = args.map(&:to_s)
  unless TRAIN_ENABLED
    warning "GUTILS_NO_TRAIN=true — skipping `ax #{argv.join(" ")}`"
    return nil
  end

  out = IO.popen(["ax", *argv], err: [:child, :out], &:read).to_s.strip
  code = $?&.exitstatus
  case code
  when 0
    info out unless out.empty?
    true
  when AX_TRAIN_NO_CHANGE
    # Accepted, and nothing moved. That is an answer, not a problem — `info`, not `warning`, or
    # every already-tracked PR in a stack reads as something going wrong.
    info out unless out.empty?
    false
  when AX_TRAIN_DOWN
    warning out
    :down
  else
    warning out.empty? ? "`ax #{argv.join(" ")}` failed (exit #{code})" : out
    false
  end
end

# The summary line every stack-wide task needs: say which PRs moved and which did not, instead of
# counting the ones we tried.
def report_train_results(results, noun)
  moved = results.select { |_pr, ok| ok == true }.map(&:first)
  refused = results.select { |_pr, ok| ok == false }.map(&:first)
  info "#{noun}: ##{moved.join(', #')}" unless moved.empty?
  warning "NOT #{noun} (#{refused.length}): ##{refused.join(', #')} — see the reasons above" unless refused.empty?
  warning "PRTrain is not running — #{results.count { |_p, ok| ok == :down }} PR(s) were not sent" if results.any? { |_p, ok| ok == :down }
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


