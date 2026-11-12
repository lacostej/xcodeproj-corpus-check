# Print verdict counts for a results folder written by judge.rb, and the projects where a check found a difference.
# Usage: ruby summary.rb RESULTS_DIR [--markdown [TITLE]]   (--markdown: for $GITHUB_STEP_SUMMARY)
require 'json'

dir, flag, title = ARGV
md = flag == '--markdown'
rs = Dir[File.join(dir, '**', '*.json')].map { |f| JSON.parse(File.read(f)) }
readable = rs.count { |r| r.dig('baseline', 'list_status') == 'ok' && r.dig('baseline', 'settings_status') == 'ok' }
checks = rs.flat_map { |r| r.select { |_, v| v.is_a?(Hash) && v.key?('verdict') }.keys }.uniq.sort
tallies = checks.to_h { |k| [k, rs.map { |r| r.dig(k, 'verdict') || '-' }.tally.sort_by { |_, v| -v }] }
diffs = rs.flat_map do |r|
  r.select { |_, v| v.is_a?(Hash) && %w[different xcodeproj-failed].include?(v['verdict']) }.map do |k, v|
    detail = v['error'] || (v['diffs'] || []).first(3).map { |d| d['key'] || d['what'] }.join(', ')
    detail = (v['only_after_xcodeproj'] || []).first(2).join(' ') if detail.to_s.empty?
    [r['project'], k, v['verdict'], detail.to_s.gsub(/\s+/, ' ')[0, 140]]
  end
end

if md
  puts "### #{title || 'Corpus check'}: #{rs.size} projects, #{readable} readable by Xcode before any save"
  puts
  puts '| Check | Verdicts |'
  puts '| --- | --- |'
  tallies.each { |k, t| puts "| `#{k}` | #{t.map { |a, b| "#{a} #{b}" }.join(', ')} |" }
  unless diffs.empty?
    puts
    puts "<details><summary>#{diffs.size} differences and failures</summary>"
    puts
    puts '| Project | Check | Verdict | First keys or error |'
    puts '| --- | --- | --- | --- |'
    diffs.each { |d| puts "| #{d.map { |c| c.to_s.gsub('|', '\|') }.join(' | ')} |" }
    puts
    puts '</details>'
  end
else
  puts "projects: #{rs.size}, harness errors: #{rs.count { |r| r['harness_error'] }}"
  puts "readable by Xcode before any save: #{readable}"
  tallies.each { |k, t| puts "#{k.ljust(14)} #{t.map { |a, b| "#{a}=#{b}" }.join('  ')}" }
  diffs.each { |d| puts "  #{d.join('  ')}" }
  # Seconds spent per check, summed over projects (recorded since judge.rb logs durations).
  secs = Hash.new(0.0)
  rs.each { |r| r.each { |k, v| secs[k] += v['seconds'].to_f if v.is_a?(Hash) && v['seconds'] } }
  puts "seconds per check: #{secs.sort_by { |_, t| -t }.map { |k, t| "#{k}=#{t.round}" }.join('  ')}" unless secs.empty?
end
