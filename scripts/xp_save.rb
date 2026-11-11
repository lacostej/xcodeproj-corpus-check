# Open and save one .xcodeproj with the Xcodeproj lib on the load path. ARGV: path, mode (save | edit).
# edit sets CURRENT_PROJECT_VERSION=4242 on every target's build configurations before saving, as fastlane's version actions do.
require 'xcodeproj'
path, mode = ARGV
project = Xcodeproj::Project.open(path)
if mode == 'edit'
  project.targets.each { |t| t.build_configurations.each { |c| c.build_settings['CURRENT_PROJECT_VERSION'] = '4242' } }
end
project.save
