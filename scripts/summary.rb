# Print verdict counts for a results folder written by judge.rb. Usage: ruby summary.rb RESULTS_DIR
require 'json'

rs = Dir[File.join(ARGV[0], '**', '*.json')].map { |f| JSON.parse(File.read(f)) }
puts "projects: #{rs.size}, harness errors: #{rs.count { |r| r['harness_error'] }}"
readable = rs.count { |r| r.dig('baseline', 'list_status') == 'ok' && r.dig('baseline', 'settings_status') == 'ok' }
puts "readable by Xcode before any save: #{readable}"
checks = rs.flat_map { |r| r.select { |_, v| v.is_a?(Hash) && v.key?('verdict') }.keys }.uniq.sort
checks.each do |k|
  tally = rs.map { |r| r.dig(k, 'verdict') || '-' }.tally.sort_by { |_, v| -v }
  puts "#{k.ljust(14)} #{tally.map { |a, b| "#{a}=#{b}" }.join('  ')}"
end
