require 'common'
require "json"
require 'active_support/time'
require_relative "../RandomScripts/jira"

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
end

Dir["#{File.dirname(__FILE__)}/components/*.rb"].each { |file| load file }


