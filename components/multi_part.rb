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
    branches = stage_branches(:up)
    branches.each do |branch|
      if to_branch(branch)
        system "git", "checkout", branch
      else
        error "merge failed"
      end
    end

    max_branch = branches.select { |b| b.match(MULTI_PART_PATTERN)[2].to_i <= max }.last
    error "No branches to merge to!" if max_branch.nil?
    system "git", "checkout", max_branch

    if to_branch($dev_branch)
      system "git", "checkout", @current
    else
      error "merge failed"
    end

    branches = branches.select { |b| b.match(MULTI_PART_PATTERN)[2].to_i <= max }

    system "git", "checkout", @current
    push_all *branches, $dev_branch, @current
  end

  desc "Make a new stage branch"
  task new_part: :before do |task, args|
    ensure_on_multi_part_branch
    match = Git.current_branch.match(MULTI_PART_PATTERN)
    base = match[1]
    num = match[2].to_i
    new_branch = "#{base}-stage-#{num + 1}"
    error "Branch #{new_branch} already exists!" if Git.branch_exists(new_branch)
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
end
