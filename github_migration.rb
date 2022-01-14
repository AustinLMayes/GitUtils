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

def slack_notify(path, branches, text)
  path = fix_path path
  workflows_dir = "#{path}/.github/workflows"
  workflows_file = "#{workflows_dir}/deploy.yml"
  Git.ensure_git path
  Dir.chdir path do
    Git.delete_branches "austin/slack-java", "austin/slack-mco", "austin/slack", remote: false
    branches.each do |info|
      base = info[0]
      suffix = info[1]
      dev_target = info[2]
      branch = "austin/slack#{suffix.empty? ? "" : "-" + suffix.downcase}"
      #@res << "#{path} - #{base} #{suffix} #{dev_target} #{branch}"
      info "Making a new branch named #{branch} based off of #{base}"
      Git.checkout_branch base
      system "git", "checkout", "-b", branch
      Git.ensure_branch branch
      error "No workflow file found @ #{workflows_file}" unless File.exists? workflows_file
      info "Writing contents to #{workflows_file}"
      File.open(workflows_file, "a") {|file| file.puts text }
      system "git", "add", "."
      system "git", "commit", "-am", "Add slack notify to workflow"
      wait_range 10, 30
      system "git", "pu"
      wait_range 20, 45
      if !dev_target.nil? && Git.branch_exists(dev_target)
        Git.checkout_branch dev_target
        error "Merge to #{dev_target} failed!" unless system "git", "merge", branch, "--no-edit"
        system "git", "pu"
        Git.checkout_branch branch
      end
      @res << GitHub.make_pr("Slack Notifications", body: "Add slack notifications", base: base, suffix: suffix)
      wait_range 40, 90
    end
  end
end

require 'find'

def do_slack(root_path)
  text = File.read(File.join(File.dirname(__FILE__), "templates/slack-notify.yml"))
  Find.find(fix_path(root_path)).each do |file|
    if File.directory?(file) && File.exists?("#{file}/.git")
      Dir.chdir(file) do
        origin_url = %x(git config --get remote.origin.url)
        done_already = Git.branch_exists("austin/slack") || (Git.branch_exists("austin/slack-java") && Git.branch_exists("austin/slack-mco"))
        unless done_already
          system "git", "checkout", "dev"
          system "git", "checkout", "master"
          system "git", "checkout", "main"
          system "git", "checkout", "production"

          path = fix_path file
          workflows_dir = "#{path}/.github/workflows"
          workflows_file = "#{workflows_dir}/deploy.yml"
          if File.exists?(workflows_file)
            has_slack = File.read(workflows_file).include?("SLACK_NOTIFICATIONS_WEB_HOOK_URL")

            if origin_url.downcase.include?("github") && !has_slack && !file.include?("GameFramework")
              desc = "[" + file.gsub("/Users/austinmayes//Projects/Java/Ziax/", "") + "] "
              branches = determine_branches(desc)
              slack_notify(file, branches, text) unless branches.empty?
            end
          end
        end
      end
    end
  end
end

def determine_branches(desc)
  Git.pull_branches "master", "master-mco", "production", "production-mco", "dev", ensure_exists: false
  has_prod = Git.branch_exists("production")
  has_mco = Git.branch_exists("production-mco")
  has_dev = Git.branch_exists("dev")
  has_master = Git.branch_exists("master")
  has_main = Git.branch_exists("main")
  if has_main && !has_master && !has_prod
    return [["main", "", nil]]
  elsif !has_prod && has_dev
    return [["master", "", "dev"]]
  elsif has_prod && !has_mco
    return [["production", "", "master"]]
  elsif has_prod && has_mco
    return [["production", "JAVA", "master"], ["production-mco", "MCO", "master-mco"]]
  elsif has_master && !has_dev
    return [["master", "", nil]]
  end
  error "#{desc} prod?#{has_prod} mco?#{has_mco} dev?#{has_dev} master?#{has_master}"
end

#to_github "~/Projects/Java/Ziax/Workspace/Games/BlockWars/BlockWarsBridges", "CoolUtils", ["master", "dev"]
#make_workflows "~/Projects/Java/Ziax/Workspace/Games/Featured/Paintball/", "Paintball", "arcade", "Paintball", [["production", "JAVA"]]
#slack_notify "~/Projects/Java/Ziax/Workspace/Games/Featured/Paintball/", [["production", "JAVA"]]

#wait_range 60, 240

begin
  do_slack("~/Projects/Java/Ziax/")
ensure
  puts "Finished! Made #{@res.length} PRs"
  puts @res
end
