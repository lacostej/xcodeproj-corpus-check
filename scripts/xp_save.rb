# Open and save one .xcodeproj with the Xcodeproj lib on the load path. ARGV: path, mode (save | edit).
# edit sets CURRENT_PROJECT_VERSION=4242 on every target's build configurations before saving, as fastlane's version actions do.
require 'xcodeproj'
require 'nanaimo' # Xcodeproj loads it lazily; load it now to check where it comes from
# A Nanaimo checkout given with -I must be the one loaded, not the installed gem.
wanted = $LOAD_PATH.find { |p| File.exist?(File.join(p, 'nanaimo.rb')) }
loaded = $LOADED_FEATURES.grep(%r{/nanaimo\.rb\z}).first
abort "nanaimo loaded from #{loaded}, expected #{wanted}" if wanted && File.realpath(loaded) != File.realpath(File.join(wanted, 'nanaimo.rb'))
path, mode = ARGV
project = Xcodeproj::Project.open(path)
if mode == 'edit'
  project.targets.each { |t| t.build_configurations.each { |c| c.build_settings['CURRENT_PROJECT_VERSION'] = '4242' } }
end
project.save
