# Download each project.pbxproj listed in corpus.tsv by its blob SHA into OUT/<owner>__<repo>/<path>.
# Only the project files are fetched, never the repositories. Usage: ruby fetch.rb corpus.tsv OUT
require 'base64'
require 'fileutils'
require 'open3'

tsv, out = ARGV
out_real = File.realpath(FileUtils.mkdir_p(out).first)
failed = 0
File.readlines(tsv, chomp: true).drop(1).each do |line|
  repo, path, sha = line.split("\t")
  dest = File.expand_path(File.join(out, repo.sub('/', '__'), path))
  raise "path escapes #{out}: #{path}" unless dest.start_with?(out_real + '/')
  next if File.exist?(dest)

  body, err, st = Open3.capture3('gh', 'api', "repos/#{repo}/git/blobs/#{sha}", '--jq', '.content')
  unless st.success?
    warn "skip #{repo} #{path}: #{err.strip}"
    failed += 1
    next
  end
  FileUtils.mkdir_p(File.dirname(dest))
  File.binwrite(dest, Base64.decode64(body))
end
warn "fetch failures: #{failed}"
