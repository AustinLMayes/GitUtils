namespace :patching do
  PATCHES_PATH = ENV["HOME"] + "/git-utils/patches"

  desc "Make patches from the given branch"
  task create: :before do |task, args|
    Git.create_patches
  end

  desc "Apply patches to the current branch"
  task apply: :before do |task, args|
    interactive = args.extras[0] == "true"
    Git.apply_patches(interactive: interactive)
  end
end
