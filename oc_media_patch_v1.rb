#!/usr/bin/ruby
# frozen_string_literal: true

require 'yaml'

path = ARGV[0]
abort('usage: oc_media_patch_v1.rb CONFIG_YAML [BENCH_PORT]') unless path && File.file?(path)

cfg = YAML.load_file(path) || {}
groups = cfg['proxy-groups'] ||= []
proxies = cfg['proxies'] ||= []
rules = cfg['rules'] ||= []
listeners = cfg['listeners'] ||= []

media_name = 'MEDIA'
bench_name = 'BENCH'
listener_name = 'bench-in'
begin
  listener_port = Integer(ARGV[1] || '7898', 10)
rescue ArgumentError
  abort('BENCH_PORT must be an integer')
end
abort('BENCH_PORT must be between 1024 and 65535') unless (1024..65_535).cover?(listener_port)

base = groups.find { |g| g.is_a?(Hash) && g['name'] == '🔰 节点选择' }
abort('base group not found: 🔰 节点选择') unless base

real_names = {}
proxies.each { |p| real_names[p['name']] = true if p.is_a?(Hash) && p['name'] }
nodes = (base['proxies'] || []).select { |name| real_names[name] }
abort('no real proxy nodes found in base group') if nodes.empty?

# Refuse a port collision instead of silently producing a broken configuration.
top_level_ports = %w[port socks-port redir-port mixed-port tproxy-port]
top_level_ports.each do |key|
  next unless cfg[key].to_i == listener_port

  abort("bench listener port #{listener_port} conflicts with #{key}")
end

listeners.each do |listener|
  next unless listener.is_a?(Hash)
  next if listener['name'] == listener_name
  next unless listener['port'].to_i == listener_port

  abort("bench listener port #{listener_port} conflicts with listener #{listener['name']}")
end

# Idempotently rebuild the two groups from real subscription nodes.
groups.reject! do |group|
  group.is_a?(Hash) && [media_name, bench_name].include?(group['name'])
end
groups.unshift(
  { 'name' => media_name, 'type' => 'select', 'proxies' => nodes.dup },
  { 'name' => bench_name, 'type' => 'select', 'proxies' => nodes.dup, 'hidden' => true }
)

# Preserve unrelated listeners and replace only our named listener.
listeners.reject! { |listener| listener.is_a?(Hash) && listener['name'] == listener_name }
listeners << {
  'name' => listener_name,
  'type' => 'mixed',
  'port' => listener_port,
  'listen' => '127.0.0.1',
  'udp' => false,
  'users' => [],
  'proxy' => bench_name
}

custom_rules = [
  'DOMAIN-SUFFIX,youtube.com,MEDIA',
  'DOMAIN-SUFFIX,youtu.be,MEDIA',
  'DOMAIN-SUFFIX,googlevideo.com,MEDIA',
  'DOMAIN-SUFFIX,ytimg.com,MEDIA',
  'DOMAIN,youtubei.googleapis.com,MEDIA',
  'DOMAIN-SUFFIX,x.com,MEDIA',
  'DOMAIN-SUFFIX,twitter.com,MEDIA',
  'DOMAIN-SUFFIX,twimg.com,MEDIA',
  'DOMAIN-SUFFIX,t.co,MEDIA',
  'DOMAIN-SUFFIX,chatgpt.com,MEDIA',
  'DOMAIN-SUFFIX,openai.com,MEDIA',
  'DOMAIN-SUFFIX,oaistatic.com,MEDIA',
  'DOMAIN-SUFFIX,oaiusercontent.com,MEDIA',
  'DOMAIN-SUFFIX,github.com,MEDIA',
  'DOMAIN-SUFFIX,githubusercontent.com,MEDIA',
  'DOMAIN-SUFFIX,githubassets.com,MEDIA',
  'DOMAIN-SUFFIX,github.io,MEDIA'
]

# Remove only rules previously owned by this feature. Cloudflare is no longer
# a BENCH target in V1.
rules.reject! do |rule|
  rule.is_a?(String) && (
    rule.match?(/,(?:MEDIA|BENCH)$/) ||
    rule == 'DOMAIN,speed.cloudflare.com,BENCH'
  )
end

# Keep every reject rule ahead of MEDIA. Explicit legacy YouTube/X routes are
# preserved but moved behind our rules, where they cannot preempt MEDIA. This
# also gives a safe insertion point when a subscription has no legacy routes.
media_domains = %w[
  youtube.com youtu.be googlevideo.com ytimg.com youtubei.googleapis.com
  x.com twitter.com twimg.com t.co
  chatgpt.com openai.com oaistatic.com oaiusercontent.com
  github.com githubusercontent.com githubassets.com github.io
]
rule_target = lambda do |rule|
  fields = rule.is_a?(String) ? rule.split(',') : []
  fields.length >= 3 ? fields[2] : nil
end
explicit_media_rule = lambda do |rule|
  fields = rule.is_a?(String) ? rule.split(',') : []
  next false unless %w[DOMAIN DOMAIN-SUFFIX].include?(fields[0]) && fields[1]

  payload = fields[1].downcase
  media_domains.any? { |domain| payload == domain || payload.end_with?(".#{domain}") }
end

legacy_media_rules = rules.select do |rule|
  explicit_media_rule.call(rule) && rule_target.call(rule) != '🛑 全球拦截'
end
rules.reject! { |rule| legacy_media_rules.include?(rule) }

last_reject = rules.rindex { |rule| rule_target.call(rule) == '🛑 全球拦截' }
insert_at = last_reject ? last_reject + 1 : 0
rules.insert(insert_at, *custom_rules, *legacy_media_rules)

cfg['profile'] = {} unless cfg['profile'].is_a?(Hash)
cfg['profile']['store-selected'] = true

File.open(path, 'w') { |file| file.write(YAML.dump(cfg)) }
puts "oc-media-v1: installed MEDIA/BENCH, #{nodes.length} nodes, bench-in:#{listener_port}, #{custom_rules.length} rules"
