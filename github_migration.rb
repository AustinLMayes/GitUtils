require 'rake'
require_relative 'common'

@res = []

def to_github(path, repo_name, branches)
  path = fix_path path
  Git.ensure_git path
  Dir.chdir path do
    origin_url = %x(git config --get remote.origin.url)
    error "Repo is already on GitHub!" if origin_url.downcase.include? "github"

    Git.pull_branches *branches

    info "Removing old origin..."
    system "git", "remote", "remove", "origin"

    info "Creating repo on GitHub..."
    system "gh", "repo", "create", "teamziax/#{repo_name}", "--private", "-y"

    info "Pushing branches up"
    system "git", "push", "origin", branches.join(" ")

    info "Moved #{repo_name} to GitHub!"
  end
end

def make_workflows(path, repo_name, category, jar_name, branches)
  path = fix_path path
  workflows_dir = "#{path}/.github/workflows"
  workflows_file = "#{workflows_dir}/deploy.yml"
  Git.ensure_git path
  text = File.read(File.join(File.dirname(__FILE__), "templates/maven-workflow.yml"))
  new_text = text.gsub("||CATEGORY||", category).gsub("||JAR_NAME||", jar_name)
  Dir.chdir path do
    branches.each do |info|
      base = info[0]
      suffix = info[1]
      branch = "workflows-#{suffix.downcase}"
      Git.checkout_branch base
      info "Making a new branch named #{branch} based off of #{base}"
      system "git", "checkout", "-b", branch
      Git.ensure_branch branch
      info "Making workflows directory @ #{workflows_dir}..."
      FileUtils.mkdir_p workflows_dir
      info "Writing contents to #{workflows_file}"
      File.open(workflows_file, "w") {|file| file.puts new_text }
      system "git", "add", "."
      system "git", "commit", "-am", "Add maven workflow file"
      wait_range 10, 30
      system "git", "pu"
      wait_range 10, 30
      @res << GitHub.make_pr("Add maven workflow file", body: "Adds the github workflow file", base: base, suffix: suffix)
      wait_range 20, 45
    end
  end
end

def slack_notify(path, repo_name, category, jar_name, branches)
  path = fix_path path
  workflows_dir = "#{path}/.github/workflows"
  workflows_file = "#{workflows_dir}/deploy.yml"
  Git.ensure_git path
  text = File.read(File.join(File.dirname(__FILE__), "templates/slack-notify.yml"))
  Dir.chdir path do
    Git.delete_branches "workflows-java", "workflows-mco"
    branches.each do |info|
      base = info[0]
      suffix = info[1]
      branch = "slack-#{suffix.downcase}"
      info "Making a new branch named #{branch} based off of #{base}"
      Git.checkout_branch base
      system "git", "checkout", "-b", branch
      Git.ensure_branch branch
      error "No workflow file found @ #{workflows_file}" unless File.exists? workflows_file
      info "Writing contents to #{workflows_file}"
      File.open(workflows_file, "a") {|file| file.puts text }
      system "git", "add", "."
      system "git", "commit", "-am", "Add slack notify to workflow"
      wait_range 40, 120
      system "git", "pu"
      wait_range 40, 120
      @res << GitHub.make_pr("Slack Notifications", body: "Add slack notifications", base: base, suffix: suffix)
      wait_range 40, 200
    end
  end
end

#to_github "~/Projects/Java/Ziax/Workspace/Games/BlockWars/BlockWarsBridges", "CoolUtils", ["master", "dev"]
#make_workflows "~/Projects/Java/Ziax/Workspace/Games/Featured/Paintball/", "Paintball", "arcade", "Paintball", [["production", "JAVA"]]
#slack_notify "~/Projects/Java/Ziax/Workspace/Games/Featured/Paintball/", "Paintball", "arcade", "Paintball", [["production", "JAVA"]]

#wait_range 60, 240

begin
  to_github "~/Projects/Java/Ziax/Libraries/ArcadeAPI", "ArcadeAPI", ["master", "master-mco", "production", "production-mco"]
  make_workflows "~/Projects/Java/Ziax/Libraries/ArcadeAPI", "ArcadeAPI", "arcade", "ArcadeAPI", [["production", "JAVA"], ["production-mco", "MCO"]]
ensure
  puts "Finished! Made #{@res.length} PRs"
  puts @res
end
