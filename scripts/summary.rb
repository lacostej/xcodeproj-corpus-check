# Print verdict counts for a results folder written by judge.rb. Usage: ruby summary.rb RESULTS_DIR
require 'json'

rs = Dir[File.join(ARGV[0], '**', '*.json')].map { |f| JSON.parse(File.read(f)) }
puts "projects: #{rs.size}, harness errors: #{rs.count { |r| r['harness_error'] }}"
readable = rs.count { |r| r.dig('baseline', 'list_status') == 'ok' && r.dig('baseline', 'settings_status') == 'ok' }
puts "readable by Xcode before any save: #{readable}"
%w[pbx-master edit-master pbx-1057 edit-1057 json json-edit cross-master cross-1057].each do |k|
  tally = rs.map { |r| r.dig(k, 'verdict') || '-' }.tally.sort_by { |_, v| -v }
  puts "#{k.ljust(12)} #{tally.map { |a, b| "#{a}=#{b}" }.join('  ')}"
end
