# Use Xcode as the judge of Xcodeproj saves. For each project under SRC (only project.pbxproj files), in throwaway copies under OUT:
#   baseline : xcodebuild -list / -showBuildSettings on the untouched project
#   pbx-<lib> : Xcodeproj <lib> opens and saves it; Xcode must report the same targets, schemes and build settings
#   edit-<lib>: then sets CURRENT_PROJECT_VERSION=4242; only settings that now contain 4242 may change
#   json      : Xcode 27.2 converts it to project.xcproj; the JSON-capable lib (JSON_LIB) opens and saves it; same checks; plus edit
#   cross-<lib>: Xcode's JSON conversion of the <lib>-saved pbxproj must equal its conversion of the original
# Swift package resolution is disabled and pointed at an empty folder per project; the folder is checked afterwards.
# Usage: ruby judge.rb SRC OUT LIBS_JSON [JOBS] [LIMIT]   (LIBS_JSON: {"master":"<lib dir>","xcodeproj":"<lib dir>"}; JSON_LIB names the label with JSON support, default xcodeproj)
# A lib may list several load paths separated by ':', e.g. "<nanaimo>/lib:<xcodeproj>/lib" to use a Nanaimo checkout.
# PROJECTS=<regexp> keeps only the projects whose name matches. A failing step's full output goes to OUT/_logs/<project>/,
# and each check records its duration in seconds.
require 'json'
require 'fileutils'
require 'open3'
require 'timeout'

SRC, OUT, LIBS_JSON, JOBS, LIMIT = ARGV
LIBS = JSON.parse(LIBS_JSON)
DEV = ENV.fetch('XCODE_DEVELOPER_DIR', '/Applications/Xcode-27.2.0.app/Contents/Developer').freeze
# Resolving packages downloads them and evaluates their Package.swift: only on a disposable runner.
ALLOW_PACKAGES = ENV['ALLOW_PACKAGES'] == '1'
SAVE = File.join(__dir__, 'xp_save.rb')
# ChimeHQ__Chime: depends on github.com/mattmassicotte/FuzzyFind, which no longer exists, so Xcode cannot read it.
EXCLUDE = [/andrd3v__CVE/, %r{ChimeHQ__Chime/Edit\.xcodeproj}].freeze
OUT_REAL = File.realpath(FileUtils.mkdir_p(OUT).first)

# Full output of a failing step, so a failure never needs a rerun to be read. Returns the path relative to OUT.
def save_log(name, step, text)
  rel = File.join('_logs', name, "#{step}.log")
  FileUtils.mkdir_p(File.dirname(File.join(OUT, rel)))
  File.write(File.join(OUT, rel), text.to_s.byteslice(-200_000, 200_000) || text.to_s)
  rel
end

NOISE = /Writing error result bundle|^\s*$/.freeze

# The lines that say what went wrong: each line with "error" and the lines after it, which carry the reason.
def error_lines(text, context: 6)
  lines = text.to_s.lines.map(&:rstrip).reject { |l| l =~ NOISE }
  keep = []
  lines.each_with_index { |l, i| keep.concat((i..i + context).to_a) if l =~ /error|•/i }
  keep.uniq.select { |i| i < lines.size }.first(20).map { |i| lines[i] }.join("\n")[0, 1500]
end

def timed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  [yield, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1)]
end

# Returns [stdout + stderr, status, stdout alone]. JSON is parsed from stdout alone: package resolution
# prints progress such as "[1/5] Fetching" on stderr, which broke parsing when the streams were merged.
def run(cmd, env: {}, timeout: 180)
  out = +''
  err = +''
  status = nil
  Open3.popen3({ 'DEVELOPER_DIR' => DEV }.merge(env), *cmd) do |i, o, e, th|
    i.close
    readers = [Thread.new { out << o.read.to_s }, Thread.new { err << e.read.to_s }]
    begin
      Timeout.timeout(timeout) { status = th.value }
    rescue Timeout::Error
      Process.kill('KILL', th.pid) rescue nil
      th.value
      readers.each(&:join)
      return [err + out, :timeout, out]
    end
    readers.each(&:join)
  end
  [err + out, status.success? ? :ok : status.exitstatus, out]
end

# Local Swift packages sit next to the project in its repository, which the corpus does not fetch. Each one gets a
# stub Package.swift declaring the products the project uses, so that Xcode can resolve the package graph. A local
# product names no package, so it goes to the package with its name, or else to the first one.
def local_package_stubs(pbxproj)
  pkgs = pbxproj.scan(/isa = XCLocalSwiftPackageReference;\s*relativePath = "?([^";]+)"?;/).flatten.uniq
  return {} if pkgs.empty?
  products = pbxproj.scan(/isa = XCSwiftPackageProductDependency;(.*?)\};/m).flatten
                    .reject { |b| b.include?('package = ') }.filter_map { |b| b[/productName = "?([^";]+)"?;/, 1] }.uniq
  stubs = pkgs.to_h { |p| [p, []] }
  products.each { |n| stubs[pkgs.find { |p| File.basename(p).casecmp?(n) } || pkgs.first] << n }
  stubs
end

# name: from the package's relative path, never from the copy dir, whose name differs between copies; Xcode lists
# a scheme under it. Target names must be unique across all packages, so they start with the package name.
def write_package_stub(dir, name, products)
  # Xcode refuses a package without products ("contains no products"), so an unused one gets one named after it.
  products = [name] if products.empty?
  targets = products.each_index.map { |i| "#{name.gsub(/[^A-Za-z0-9]/, '_')}Stub#{i}" }
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, 'Package.swift'), <<~SWIFT)
    // swift-tools-version:5.9
    // Stub written by xcodeproj-corpus-check: the corpus has the project file only, not this local package.
    import PackageDescription
    let package = Package(
      name: #{name.inspect},
      products: [#{products.zip(targets).map { |p, t| ".library(name: #{p.inspect}, targets: [#{t.inspect}])" }.join(', ')}],
      targets: [#{targets.map { |t| ".target(name: #{t.inspect}, path: #{"Sources/#{t}".inspect})" }.join(', ')}]
    )
  SWIFT
  targets.each do |t|
    FileUtils.mkdir_p(File.join(dir, 'Sources', t))
    File.write(File.join(dir, 'Sources', t, "#{t}.swift"), "public enum #{t} {}\n")
  end
end

# Inside a copy dir only; refuse anything that would resolve outside OUT. A project with local packages is copied as
# many folders deep as its paths go up ("../"), so that the stubs land inside the copy dir too.
def fresh_copy(src_xcodeproj, dir)
  real_parent = File.realpath(FileUtils.mkdir_p(File.dirname(dir)).first)
  raise "outside OUT: #{dir}" unless real_parent.start_with?(OUT_REAL)
  FileUtils.rm_rf(dir)
  stubs = local_package_stubs(File.read(File.join(src_xcodeproj, 'project.pbxproj')))
  depth = stubs.keys.map { |p| p.scan('../').size }.max.to_i
  home = File.join(dir, *(['nest'] * depth))
  FileUtils.mkdir_p(home)
  FileUtils.cp_r(src_xcodeproj, home)
  stubs.each do |rel, products|
    target = File.expand_path(rel, home)
    inside = target == File.expand_path(dir) || target.start_with?(File.expand_path(dir) + '/')
    raise "local package outside the copy: #{rel}" unless inside
    name = File.basename(rel.chomp('/'))
    name = 'LocalPackage' if ['.', '..', ''].include?(name)
    write_package_stub(target, name, products) unless File.exist?(File.join(target, 'Package.swift'))
  end
  File.join(home, File.basename(src_xcodeproj))
end

# All copies of one project share one package folder, OUT/<project>/.pkgs, so each package downloads once.
def shared_packages_dir(proj)
  File.join(OUT_REAL, File.realpath(proj).delete_prefix(OUT_REAL + '/').split('/').first, '.pkgs')
end

def xcode_view(proj, log_as: nil)
  dir = File.dirname(proj)
  pkgs = ALLOW_PACKAGES ? shared_packages_dir(proj) : File.join(dir, '.pkgs')
  FileUtils.mkdir_p(pkgs)
  flags = ['-clonedSourcePackagesDirPath', pkgs]
  # The system git reads the runner's git config, which rewrites SSH package URLs (git@github.com:) to HTTPS.
  flags += ['-scmProvider', 'system'] if ALLOW_PACKAGES
  flags = ['-disableAutomaticPackageResolution', '-skipPackageUpdates'] + flags unless ALLOW_PACKAGES
  list_out, list_st, list_json = run(['xcodebuild', '-list', '-json', '-project', proj] + flags)
  # A package fetch can fail once on the network ("Couldn't fetch updates from remote repositories"): retry once.
  list_out, list_st, list_json = run(['xcodebuild', '-list', '-json', '-project', proj] + flags) if ALLOW_PACKAGES && list_st != :ok && list_out.include?('Could not resolve package dependencies')
  bs_out, bs_st, bs_json = run(['xcodebuild', '-showBuildSettings', '-json', '-alltargets', '-project', proj,
                                "-IDECustomDerivedDataLocation=#{File.join(dir, '.dd')}"] + flags)
  # xcodebuild reports /private/tmp paths as /tmp, so replace every spelling of the copy and its parent.
  spell = ->(p) { [File.realpath(p), p].flat_map { |x| [x, x.sub(%r{\A/private/}, '/')] }.uniq.sort_by { |x| -x.size } }
  norm = lambda do |s|
    spell.(dir).each { |x| s = s.gsub(x, '<DIR>') }
    spell.(File.dirname(dir)).each { |x| s = s.gsub(x, '<BASE>') }
    s
  end
  list = (JSON.parse(norm.(list_json[/\{.*\}/m] || '')) rescue nil)
  settings = (JSON.parse(norm.(bs_json[/\[.*\]/m] || '')) rescue nil)
  {
    list_status: list_st, settings_status: bs_st,
    list: list && list['project'] && list['project'].slice('targets', 'configurations', 'schemes').transform_values(&:sort),
    settings: settings && settings.each_with_index.to_h { |e, i| ["#{e['target']}##{i}", e['buildSettings']] },
    error: ([list_st, bs_st].any? { |s| s != :ok } ? error_lines(list_out + bs_out) : nil),
    log: ([list_st, bs_st].any? { |s| s != :ok } && log_as ? save_log(*log_as, "== xcodebuild -list (#{list_st})\n#{list_out}\n== xcodebuild -showBuildSettings (#{bs_st})\n#{bs_out}") : nil),
    packages_fetched: Dir.glob(File.join(pkgs, '{checkouts,repositories}', '*')).size
  }
end

def compare(before, after, allow: nil)
  return { verdict: 'xcode-failed-before' } if before[:settings].nil? || before[:list].nil?
  return { verdict: 'xcode-failed-after', error: after[:error], log: after[:log] } if after[:settings].nil? || after[:list].nil?
  diffs = []
  diffs << { what: 'list', before: before[:list], after: after[:list] } unless before[:list] == after[:list]
  (before[:settings].keys | after[:settings].keys).each do |t|
    b = before[:settings][t] || {}
    a = after[:settings][t] || {}
    (b.keys | a.keys).each do |k|
      next if b[k] == a[k]
      next if allow && a[k].to_s.include?(allow) && !b[k].to_s.include?(allow)
      diffs << { what: 'setting', target: t, key: k, before: b[k].to_s[0, 160], after: a[k].to_s[0, 160] }
    end
  end
  if allow
    seen = before[:settings].keys.count { |t| (after[:settings][t] || {})['CURRENT_PROJECT_VERSION'] == allow }
    diffs << { what: 'edit-not-visible', targets_with_edit: seen } if seen.zero? && !before[:settings].empty?
  end
  { verdict: diffs.empty? ? 'same' : 'different', diffs: diffs.first(25), diff_count: diffs.size }
end

def xp(lib, proj, mode, log_as: nil)
  out, st = run(['ruby', *lib.split(':').flat_map { |l| ['-I', l] }, SAVE, proj, mode], timeout: 300)
  return nil if st == :ok
  save_log(*log_as, "exit #{st}\n#{out}") if log_as
  # xp_save prints one "xp_save error:" line for an exception; an abort, crash or timeout keeps the last lines.
  line = out.lines.find { |l| l.start_with?('xp_save error: ') }
  return line.delete_prefix('xp_save error: ').strip[0, 300] if line
  out.lines.reject { |l| l.include?("doesn't know about") || l.include?('If this attribute') }.last(2).join.strip[0, 300]
end

def judge(src_xcodeproj, name)
  base = File.join(OUT, name)
  r = { project: name }
  orig = fresh_copy(src_xcodeproj, File.join(base, 'baseline'))
  before, secs = timed { xcode_view(orig, log_as: [name, 'baseline']) }
  r[:baseline] = before.slice(:list_status, :settings_status, :error, :log, :packages_fetched).merge(targets: before[:settings]&.size, seconds: secs)
  LIBS.each do |label, lib|
    proj = fresh_copy(src_xcodeproj, File.join(base, "pbx-#{label}"))
    after = nil # set inside the timed block, read by the edit step
    r["pbx-#{label}"], secs = timed do
      err = xp(lib, proj, 'save', log_as: [name, "pbx-#{label}-xcodeproj"])
      err ? { verdict: 'xcodeproj-failed', error: err, log: "_logs/#{name}/pbx-#{label}-xcodeproj.log" } : compare(before, after = xcode_view(proj, log_as: [name, "pbx-#{label}-xcode"]))
    end
    r["pbx-#{label}"][:seconds] = secs
    next if r["pbx-#{label}"][:verdict] == 'xcodeproj-failed'
    r["edit-#{label}"], secs = timed do
      err = xp(lib, proj, 'edit', log_as: [name, "edit-#{label}-xcodeproj"])
      err ? { verdict: 'xcodeproj-failed', error: err, log: "_logs/#{name}/edit-#{label}-xcodeproj.log" } : compare(after, xcode_view(proj, log_as: [name, "edit-#{label}-xcode"]), allow: '4242')
    end
    r["edit-#{label}"][:seconds] = secs
  end
  # JSON format, only with a lib that supports it
  if (lib = LIBS[ENV.fetch('JSON_LIB', 'xcodeproj')])
    proj = fresh_copy(src_xcodeproj, File.join(base, 'json'))
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, st = run(['xcodebuild', '-convert-project', 'Xcode Project', '-project', proj, "-IDECustomDerivedDataLocation=#{File.join(File.dirname(proj), '.dd')}"])
    xcproj = File.join(proj, 'project.xcproj')
    if st != :ok || !File.exist?(xcproj)
      r['json'] = { verdict: 'xcode-convert-failed', error: error_lines(out), log: save_log(name, 'json-convert', "exit #{st}\n#{out}"),
                    seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1) }
    else
      xcode_json = File.read(xcproj)
      jbefore = xcode_view(proj, log_as: [name, 'json-before'])
      err = xp(lib, proj, 'save', log_as: [name, 'json-xcodeproj'])
      r['json'] = err ? { verdict: 'xcodeproj-failed', error: err, log: "_logs/#{name}/json-xcodeproj.log" } : compare(jbefore, jafter = xcode_view(proj, log_as: [name, 'json-after'])).merge(xcproj_identical: File.read(xcproj) == xcode_json)
      r['json'][:seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1)
      unless err
        r['json-edit'], secs = timed do
          err = xp(lib, proj, 'edit', log_as: [name, 'json-edit-xcodeproj'])
          err ? { verdict: 'xcodeproj-failed', error: err, log: "_logs/#{name}/json-edit-xcodeproj.log" } : compare(jafter, xcode_view(proj, log_as: [name, 'json-edit-xcode']), allow: '4242')
        end
        r['json-edit'][:seconds] = secs
      end
    end
  end
  # cross-<lib>: Xcode's JSON conversion of the Xcodeproj-saved pbxproj must equal its conversion of the original.
  # This sees build phases (copy destinations, scripts), which -list and -showBuildSettings do not show.
  if xcode_json
    LIBS.each do |label, l|
      next if r["pbx-#{label}"].is_a?(Hash) && r["pbx-#{label}"][:verdict] == 'xcodeproj-failed'
      cross = fresh_copy(src_xcodeproj, File.join(base, "cross-#{label}"))
      next if xp(l, cross, 'save', log_as: [name, "cross-#{label}-xcodeproj"])
      (o2, st2), secs = timed { run(['xcodebuild', '-convert-project', 'Xcode Project', '-project', cross, "-IDECustomDerivedDataLocation=#{File.join(File.dirname(cross), '.dd')}"]) }
      cx = File.join(cross, 'project.xcproj')
      r["cross-#{label}"] = if st2 == :ok && File.exist?(cx)
                              a = File.read(cx).lines
                              b = xcode_json.lines
                              { verdict: a == b ? 'same' : 'different', only_in_xcode: (b - a).map(&:strip).first(8), only_after_xcodeproj: (a - b).map(&:strip).first(8) }
                            else
                              { verdict: 'xcode-convert-failed', error: error_lines(o2), log: save_log(name, "cross-#{label}-convert", "exit #{st2}\n#{o2}") }
                            end
      r["cross-#{label}"][:seconds] = secs
    end
  end
  r[:packages_fetched_total] = Dir.glob(File.join(base, '{.pkgs,*/.pkgs,*/**/.pkgs}', '{checkouts,repositories}', '*')).uniq.size
  r
end

projects = Dir.glob(File.join(SRC, '**', '*.xcodeproj')).sort.reject { |p| EXCLUDE.any? { |re| p =~ re } }
projects = projects.select { |p| File.exist?(File.join(p, 'project.pbxproj')) }
projects = projects.first(LIMIT.to_i) if LIMIT && !LIMIT.empty?
if (only = ENV['PROJECTS']) && !only.empty?
  re = Regexp.new(only)
  projects = projects.select { |p| p.sub("#{SRC}/", '').tr('/', '_') =~ re }
end
# SHARD=i/n keeps every n-th project starting at i, so several runners split the corpus.
if (shard = ENV['SHARD']) && !shard.empty?
  i, n = shard.split('/').map(&:to_i)
  projects = projects.each_with_index.select { |_, k| k % n == i }.map(&:first)
end
# ONLY_PACKAGES=1 keeps the projects that use Swift packages (the ones a local run cannot judge).
projects = projects.select { |p| File.read(File.join(p, 'project.pbxproj')).include?('SwiftPackageReference') } if ENV['ONLY_PACKAGES'] == '1'
queue = Queue.new
projects.each { |p| queue << p }
FileUtils.mkdir_p(File.join(OUT, '_results'))
$stdout.sync = true
started = Time.now
done = 0
progress = Mutex.new
puts "#{projects.size} projects, #{(JOBS || 4).to_i} at a time"
workers = (JOBS || 4).to_i.times.map do
  Thread.new do
    while (p = (queue.pop(true) rescue nil))
      name = p.sub("#{SRC}/", '').tr('/', '_')
      res = begin
        judge(p, name)
      rescue StandardError => e
        { project: name, harness_error: "#{e.class}: #{e.message}", log: save_log(name, 'harness', (["#{e.class}: #{e.message}"] + e.backtrace.to_a).join("\n")) }
      end
      File.write(File.join(OUT, '_results', "#{name}.json"), JSON.pretty_generate(res))
      # One progress line per project on stdout: count, elapsed time, and each check's verdict.
      verdicts = res.filter_map { |k, v| "#{k}=#{v[:verdict]}" if v.is_a?(Hash) && v[:verdict] }
      verdicts.unshift("harness-error: #{res[:harness_error]}") if res[:harness_error]
      progress.synchronize do
        done += 1
        puts format('[%d/%d %dm] %s  %s', done, projects.size, (Time.now - started) / 60, name, verdicts.join(' '))
      end
    end
  end
end
workers.each(&:join)
