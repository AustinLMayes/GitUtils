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

  def stage_branches(direction = :up, branch: nil, inclusive: false)
    branch ||= Git.current_branch
    ensure_multi_part_branch(branch)
    match = branch.match(MULTI_PART_PATTERN)
    base = match[1]
    num = match[2].to_i
    branches = []
    if inclusive
      branches << branch
    end
    if direction == :down
      branch = "austin/#{base}-stage-#{num - 1}"
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

  desc "Create patches for all stage branches"
  task create_patches: :before do |task, args|
    ensure_on_multi_part_branch
    system "git", "stash"
    FileUtils.rm_rf Git::PATCHES_PATH + "/" + File.basename(Dir.pwd) + "/mp/" + Git.current_branch.match(MULTI_PART_PATTERN)[1]
    first = stage_branches(:down, inclusive: true).last
    branches = stage_branches(:up, branch: first, inclusive: true)
    prev = "production"
    branches.each do |branch|
      system "git", "checkout", branch
      Git.create_patches(base: prev, prefix: "s-" + branch.match(MULTI_PART_PATTERN)[2], path: "mp/#{branch.match(MULTI_PART_PATTERN)[1]}")
      prev = branch
    end
    system "git", "checkout", @current
  end

  desc "Apply patches for stage branches"
  task apply_patches: :before do |task, args|
    current = args.extras[0] == "true"
    ensure_on_multi_part_branch
    system "git", "stash"
    branches = stage_branches(:up, inclusive: current)
    branches += branches_from_patches(Git.current_branch)
    branches.uniq!
    if current
      prev = stage_branches(:down).first
      prev = "production" if prev.nil?
      system "git", "checkout", prev
    end
    branches.each do |branch|
      system "git", "branch", "-D", branch
    end
    branches.each do |branch|
      system "git", "go", branch
      info "Applying patches for #{branch}"
      Git.apply_patches(prefix: "s-" + branch.match(MULTI_PART_PATTERN)[2], path: "mp/#{branch.match(MULTI_PART_PATTERN)[1]}")
    end
    system "git", "checkout", @current
  end

  def branches_from_patches(current)
    base = current.match(MULTI_PART_PATTERN)[1]
    min = current.match(MULTI_PART_PATTERN)[2].to_i
    Dir.glob(Git::PATCHES_PATH + "/" + File.basename(Dir.pwd) + "/mp/#{base}/*").map do |file|
      "austin/" + base + "-stage-" + File.basename(file).split("-")[1]
    end.uniq.select do |branch|
      branch.match(MULTI_PART_PATTERN)[2].to_i > min
    end.sort_by do |branch|
      branch.match(MULTI_PART_PATTERN)[2].to_i
    end
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
