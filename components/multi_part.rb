namespace :mp do
  MULTI_PART_PATTERN = /austin\/(.+)-stage-(\d+)/

  def ensure_on_multi_part_branch
    ensure_multi_part_branch(Git.current_branch)
  end

  def ensure_multi_part_branch(part)
    unless part =~ MULTI_PART_PATTERN
      error "Invalid multi-part branch name: #{part}"
    end
  end

  def stage_branches(direction = :up, branch: nil)
    branch ||= Git.current_branch
    ensure_multi_part_branch(branch)
    match = branch.match(MULTI_PART_PATTERN)
    base = match[1]
    num = match[2].to_i
    branches = []
    if direction == :down
      branch = "austin/#{base}-stage-#{num - 1}"
      puts branch
      while Git.branch_exists(branch)
        branches << branch
        num -= 1
        branch = "austin/#{base}-stage-#{num - 1}"
      end
    else
      branch = "austin/#{base}-stage-#{num + 1}"
      while Git.branch_exists(branch)
        branches << branch
        num += 1
        branch = "austin/#{base}-stage-#{num + 1}"
      end
    end

    branches
  end

  desc "Merge the current stage branch to all downstream branches"
  task merge_down: :before do |task, args|
    ensure_on_multi_part_branch
    max = args.extras[0].nil? ? Float::INFINITY : args.extras[0].to_i
    try_build = args.extras[1] == "build"
    branches = stage_branches(:up)
    if try_build
      system "./gradlew", "classes"
      error "Build failed on branch #{@current}" unless $?.success?
    end
    branches.each do |branch|
      if to_branch(branch, strategy: :rebase)
        system "git", "checkout", branch
        if try_build
          system "./gradlew", "classes"
          error "Build failed on branch #{branch}" unless $?.success?
        end
      else
        error "merge failed"
      end
    end

    max_branch = branches.select { |b| b.match(MULTI_PART_PATTERN)[2].to_i <= max }.last
    max_branch = @current if max_branch.nil? && @current.match(MULTI_PART_PATTERN)[2].to_i <= max
    error "No branches to merge to!" if max_branch.nil?
    system "git", "checkout", max_branch

    Git.pull_branches $dev_branch
    system "git", "checkout", max_branch

    if to_branch($dev_branch)
      system "git", "checkout", @current
    else
      error "merge failed"
    end

    branches = branches.select { |b| b.match(MULTI_PART_PATTERN)[2].to_i <= max }

    system "git", "checkout", @current
    push_all *branches, $dev_branch, @current, force: true
  end

  desc "Make a new stage branch"
  task new_part: :before do |task, args|
    ensure_on_multi_part_branch
    match = Git.current_branch.match(MULTI_PART_PATTERN)
    base = match[1]
    num = match[2].to_i
    new_branch = "#{base}-stage-#{num + 1}"
    error "Branch #{new_branch} already exists!" if Git.branch_exists("austin/" + new_branch)
    make_branch new_branch, @current
  end

  desc "Make a new stage branch at the next index and move all future branches up one"
  task new_part_and_move: :before do |task, args|
    ensure_on_multi_part_branch
    match = Git.current_branch.match(MULTI_PART_PATTERN)
    base = match[1]
    num = match[2].to_i
    new_branch = "#{base}-stage-#{num + 1}"
    if Git.branch_exists("austin/" + new_branch)
      system "git", "stash"
      info "Branch #{new_branch} already exists! Moving all future branches up one"
      # move all future branches up one
      branches = stage_branches(:up)
      info "Going to move #{branches.count} branches up one"
      branches.reverse.each do |branch|
        system "git", "checkout", branch
        new_num = branch.match(MULTI_PART_PATTERN)[2].to_i + 1
        new_branch = "austin/#{base}-stage-#{new_num}"
        system "git", "branch", "-m", new_branch
        info "Renamed #{branch} to #{new_branch}"
      end
      info "Renamed all branches"
      system "git", "stash", "pop"
      system "git", "checkout", @current
      new_branch = "#{base}-stage-#{num + 1}"
    else
      info "Branch #{new_branch} does not exist! Creating it"
    end
    make_branch new_branch, @current
  end

  desc "Make a new base multi-part branch"
  task new_base: :before do |task, args|
    system "git", "stash"
    base = args.extras[0]
    error "Branch austin/#{base}-stage-1 already exists!" if Git.branch_exists("austin/#{base}-stage-1")
    make_branch "#{base}-stage-1", "production"
    system "git", "stash", "pop"
  end

  desc "Go up one stage"
  task next_part: :before do |task, args|
    ensure_on_multi_part_branch
    branches = stage_branches(:up)
    error "No branches to go up to!" if branches.empty?
    system "git", "stash"
    system "git", "checkout", branches.first
    system "git", "stash", "pop"
  end

  desc "Go down one stage"
  task prev_part: :before do |task, args|
    ensure_on_multi_part_branch
    branches = stage_branches(:down)
    error "No branches to go down to!" if branches.empty?
    system "git", "stash"
    system "git", "checkout", branches.first
    system "git", "stash", "pop"
  end

  desc "Go down to the last stage"
  task last_part: :before do |task, args|
    ensure_on_multi_part_branch
    branches = stage_branches(:up)
    error "No branches to go down to!" if branches.empty?
    system "git", "stash"
    system "git", "checkout", branches.last
    system "git", "stash", "pop"
  end

  desc "Go up to the first stage"
  task first_part: :before do |task, args|
    ensure_on_multi_part_branch
    branches = stage_branches(:down)
    error "No branches to go up to!" if branches.empty?
    system "git", "stash"
    system "git", "checkout", branches.last
    system "git", "stash", "pop"
  end

  desc "Run ./gradlew classes on each stage branch amd stop on failure"
  task test_build: :before do |task, args|
    ensure_on_multi_part_branch
    branches = stage_branches(:up)
    error "No branches to test build!" if branches.empty?
    branches.each do |branch|
      system "git", "checkout", branch
      system "./gradlew", "classes"
      error "Build failed on branch #{branch}" unless $?.success?
    end
    system "git", "checkout", @current
  end

  desc "Create PR for current stage branch based on previous stage branch"
  task pr: :before do |task, args|
    title = args.extras[0..-1].join(" ")
    ensure_on_multi_part_branch
    branches = stage_branches(:down)
    error "No branches to create PR from!" if branches.empty?
    GitHub.make_pr(title, suffix: "", base: branches.first)
  end
end
