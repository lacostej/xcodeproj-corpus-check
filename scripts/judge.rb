# Use Xcode as the judge of Xcodeproj saves. For each project under SRC (only project.pbxproj files), in throwaway copies under OUT:
#   baseline : xcodebuild -list / -showBuildSettings on the untouched project
#   pbx-<lib> : Xcodeproj <lib> opens and saves it; Xcode must report the same targets, schemes and build settings
#   edit-<lib>: then sets CURRENT_PROJECT_VERSION=4242; only settings that now contain 4242 may change
#   json      : Xcode 27.2 converts it to project.xcproj; the JSON-capable lib (JSON_LIB) opens and saves it; same checks; plus edit
#   cross-<lib>: Xcode's JSON conversion of the <lib>-saved pbxproj must equal its conversion of the original
# Swift package resolution is disabled and pointed at an empty folder per project; the folder is checked afterwards.
# Usage: ruby judge.rb SRC OUT LIBS_JSON [JOBS] [LIMIT]   (LIBS_JSON: {"master":"<lib dir>","pr":"<lib dir>"}; JSON_LIB names the label with JSON support, default pr)
# A lib may list several load paths separated by ':', e.g. "<nanaimo>/lib:<xcodeproj>/lib" to use a Nanaimo checkout.
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
EXCLUDE = [/andrd3v__CVE/].freeze
OUT_REAL = File.realpath(FileUtils.mkdir_p(OUT).first)

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

# Inside a copy dir only; refuse anything that would resolve outside OUT.
def fresh_copy(src_xcodeproj, dir)
  real_parent = File.realpath(FileUtils.mkdir_p(File.dirname(dir)).first)
  raise "outside OUT: #{dir}" unless real_parent.start_with?(OUT_REAL)
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  FileUtils.cp_r(src_xcodeproj, dir)
  File.join(dir, File.basename(src_xcodeproj))
end

def xcode_view(proj)
  dir = File.dirname(proj)
  # With resolution on, all copies of one project share one package folder, so each package downloads once.
  pkgs = ALLOW_PACKAGES ? File.join(File.dirname(dir), '.pkgs') : File.join(dir, '.pkgs')
  FileUtils.mkdir_p(pkgs)
  flags = ['-clonedSourcePackagesDirPath', pkgs]
  flags = ['-disableAutomaticPackageResolution', '-skipPackageUpdates'] + flags unless ALLOW_PACKAGES
  list_out, list_st, list_json = run(['xcodebuild', '-list', '-json', '-project', proj] + flags)
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
    error: ([list_st, bs_st].any? { |s| s != :ok } ? (list_out + bs_out).lines.grep(/error/i).first(3).join : nil),
    packages_fetched: Dir.glob(File.join(pkgs, '{checkouts,repositories}', '*')).size
  }
end

def compare(before, after, allow: nil)
  return { verdict: 'xcode-failed-before' } if before[:settings].nil? || before[:list].nil?
  return { verdict: 'xcode-failed-after', error: after[:error] } if after[:settings].nil? || after[:list].nil?
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

def xp(lib, proj, mode)
  out, st = run(['ruby', *lib.split(':').flat_map { |l| ['-I', l] }, SAVE, proj, mode], timeout: 300)
  return nil if st == :ok
  # xp_save prints one "xp_save error:" line for an exception; an abort, crash or timeout keeps the last lines.
  line = out.lines.find { |l| l.start_with?('xp_save error: ') }
  return line.delete_prefix('xp_save error: ').strip[0, 300] if line
  out.lines.reject { |l| l.include?("doesn't know about") || l.include?('If this attribute') }.last(2).join.strip[0, 300]
end

def judge(src_xcodeproj, name)
  base = File.join(OUT, name)
  r = { project: name }
  orig = fresh_copy(src_xcodeproj, File.join(base, 'baseline'))
  before = xcode_view(orig)
  r[:baseline] = before.slice(:list_status, :settings_status, :error, :packages_fetched).merge(targets: before[:settings]&.size)
  LIBS.each do |label, lib|
    proj = fresh_copy(src_xcodeproj, File.join(base, "pbx-#{label}"))
    err = xp(lib, proj, 'save')
    r["pbx-#{label}"] = err ? { verdict: 'xcodeproj-failed', error: err } : compare(before, after = xcode_view(proj))
    next if err
    err = xp(lib, proj, 'edit')
    r["edit-#{label}"] = err ? { verdict: 'xcodeproj-failed', error: err } : compare(after, xcode_view(proj), allow: '4242')
  end
  # JSON format, only with a lib that supports it
  if (lib = LIBS[ENV.fetch('JSON_LIB', 'pr')])
    proj = fresh_copy(src_xcodeproj, File.join(base, 'json'))
    out, st = run(['xcodebuild', '-convert-project', 'Xcode Project', '-project', proj, "-IDECustomDerivedDataLocation=#{File.join(File.dirname(proj), '.dd')}"])
    xcproj = File.join(proj, 'project.xcproj')
    if st != :ok || !File.exist?(xcproj)
      r['json'] = { verdict: 'xcode-convert-failed', error: out.lines.grep(/error|•/).first(2).join.strip[0, 200] }
    else
      xcode_json = File.read(xcproj)
      jbefore = xcode_view(proj)
      err = xp(lib, proj, 'save')
      r['json'] = err ? { verdict: 'xcodeproj-failed', error: err } : compare(jbefore, jafter = xcode_view(proj)).merge(xcproj_identical: File.read(xcproj) == xcode_json)
      unless err
        err = xp(lib, proj, 'edit')
        r['json-edit'] = err ? { verdict: 'xcodeproj-failed', error: err } : compare(jafter, xcode_view(proj), allow: '4242')
      end
    end
  end
  # cross-<lib>: Xcode's JSON conversion of the Xcodeproj-saved pbxproj must equal its conversion of the original.
  # This sees build phases (copy destinations, scripts), which -list and -showBuildSettings do not show.
  if xcode_json
    LIBS.each do |label, l|
      next if r["pbx-#{label}"].is_a?(Hash) && r["pbx-#{label}"][:verdict] == 'xcodeproj-failed'
      cross = fresh_copy(src_xcodeproj, File.join(base, "cross-#{label}"))
      next if xp(l, cross, 'save')
      _o, st2 = run(['xcodebuild', '-convert-project', 'Xcode Project', '-project', cross, "-IDECustomDerivedDataLocation=#{File.join(File.dirname(cross), '.dd')}"])
      cx = File.join(cross, 'project.xcproj')
      r["cross-#{label}"] = if st2 == :ok && File.exist?(cx)
                              a = File.read(cx).lines
                              b = xcode_json.lines
                              { verdict: a == b ? 'same' : 'different', only_in_xcode: (b - a).map(&:strip).first(8), only_after_xcodeproj: (a - b).map(&:strip).first(8) }
                            else
                              { verdict: 'xcode-convert-failed' }
                            end
    end
  end
  r[:packages_fetched_total] = Dir.glob(File.join(base, '*', '.pkgs', '{checkouts,repositories}', '*')).size
  r
end

projects = Dir.glob(File.join(SRC, '**', '*.xcodeproj')).sort.reject { |p| EXCLUDE.any? { |re| p =~ re } }
projects = projects.select { |p| File.exist?(File.join(p, 'project.pbxproj')) }
projects = projects.first(LIMIT.to_i) if LIMIT && !LIMIT.empty?
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
        { project: name, harness_error: "#{e.class}: #{e.message}" }
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
