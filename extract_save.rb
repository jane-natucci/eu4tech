# Reads an EU4 save (not Ironman) made on the first day of a campaign and writes forces.json:
# for every country, the armies and fleets the game built for it at the start, its manpower
# and sailors, treasury, monthly income and where it comes from, tradition, prestige,
# stability and tech levels. The game builds starting forces itself (a share of each
# country's force limit) and the files only hold the rules, so a save is the one place the
# result can be read from.
#
#   ruby extract_save.rb "/path/to/Save.eu4"
#
# A save is one campaign: its DLC and settings shape what it holds, and it covers only the
# date it was made on. (A save is a plain zip; the system unzip opens it.) The output is Paradox's game data, so it's gitignored, never committed.
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "time"

Encoding.default_external = Encoding::UTF_8

SAVE = ARGV[0] or abort "Usage: ruby extract_save.rb /path/to/Save.eu4"
GAME = ARGV[1] || ENV.fetch("EU4_GAME_DIR",
  File.expand_path("~/Library/Application Support/Steam/steamapps/common/Europa Universalis IV"))
OUT = File.join(__dir__, "forces.json")
abort "No save at #{SAVE}" unless File.exist?(SAVE)

# --- Unit names and kinds, from the game files ---------------------------------------------
def read_script(path)
  raw = File.binread(path)
  utf8 = raw.dup.force_encoding("UTF-8")
  utf8.valid_encoding? ? utf8.sub(/\A﻿/, "") : raw.force_encoding("windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
end

NAMES = {}
Dir[File.join(GAME, "localisation", "*_l_english.yml")].sort.each do |f|
  File.read(f, encoding: "bom|utf-8").scan(/^\s*([\w.]+):\d*\s+"(.*)"\s*$/) { |k, v| NAMES[k] ||= v }
end
unit_info = {}
Dir[File.join(GAME, "common/units/*.txt")].each do |f|
  id = File.basename(f, ".txt")
  kind = read_script(f)[/^\s*type\s*=\s*(\w+)/, 1]
  unit_info[id] = { name: NAMES[id] || id.tr("_", " "), kind: kind } if kind
end

# --- Unpack the save -----------------------------------------------------------------------------
dir = Dir.mktmpdir("eu4save")
_, err, status = Open3.capture3("unzip", "-o", "-q", SAVE, "-d", dir)
abort "Couldn't unzip the save: #{err}" unless status.success?
gamestate = File.join(dir, "gamestate")
abort "No gamestate in the save, or it is binary (Ironman saves can't be read)." unless File.exist?(gamestate) && File.binread(gamestate, 6) == "EU4txt"

meta = File.binread(File.join(dir, "meta")).force_encoding("windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
date = meta[/^date=(\S+)/, 1]
player = meta[/^player="([^"]+)"/, 1]
dlc = meta[/dlc_enabled=\{(.*?)\}/m, 1].to_s.scan(/"([^"]+)"/).flatten

# --- Read each country's block --------------------------------------------------------------------------
SCALARS = %w[manpower max_manpower sailors max_sailors treasury estimated_monthly_income land_maintenance naval_maintenance
             army_tradition navy_tradition prestige stability legitimacy devotion splendor loan_size estimated_loan development
             num_of_cities navy_strength].freeze

def parse_country(lines)
  out = { armies: [], navies: [], income: nil, expense: nil, income_table: [] }
  ctx = nil
  cur = nil
  sub = nil
  lines.each do |line|
    depth = line[/\A\t*/].size
    text = line.strip
    if depth == 2
      # A block of units closes on its own line at depth 2: keep what it collected.
      (ctx == "army" ? out[:armies] : out[:navies]) << cur if cur && text == "}"
      ctx = nil
      cur = nil
      if (m = text.match(/\A(\w+)=\{\z/))
        ctx = m[1]
        cur = { regiments: Hash.new(0), ships: Hash.new(0) } if %w[army navy].include?(ctx)
        sub = nil
      elsif (m = text.match(/\A(\w+)=([-\d.]+)\z/)) && SCALARS.include?(m[1])
        out[m[1].to_sym] = m[2].include?(".") ? m[2].to_f : m[2].to_i
      end
    elsif ctx == "army" || ctx == "navy"
      if depth == 3
        if (m = text.match(/\Aname="(.*)"\z/)) then cur[:name] = m[1]
        elsif (m = text.match(/\Alocation=(\d+)\z/)) then cur[:location] = m[1].to_i
        end
      elsif depth == 4 && (m = text.match(/\Atype="(\w+)"\z/))
        (ctx == "army" ? cur[:regiments] : cur[:ships])[m[1]] += 1
      end
      # the block closes on its own line at depth 2
    elsif ctx == "technology" && depth == 3 && (m = text.match(/\A(adm|dip|mil)_tech=(\d+)\z/))
      (out[:tech] ||= {})[m[1]] = m[2].to_i
    elsif ctx == "ledger" && depth == 3
      sub = text[/\A(\w+)=\{\z/, 1] || sub
      if (m = text.match(/\Alastmonthincome=([-\d.]+)\z/)) then out[:income] = m[1].to_f
      elsif (m = text.match(/\Alastmonthexpense=([-\d.]+)\z/)) then out[:expense] = m[1].to_f
      end
    elsif ctx == "ledger" && depth == 4 && sub == "lastmonthincometable"
      out[:income_table] = text.split.map(&:to_f)
    elsif ctx == "sub_unit" && depth == 3 && (m = text.match(/\A(\w+)="(\w+)"\z/))
      (out[:best] ||= {})[m[1]] = m[2]
    elsif ctx == "num_subunits" && depth == 3 && (m = text.match(/\Anormal=(\d+)\z/))
      out[:subunits] = m[1].to_i
    end
  end
  out
end

countries = {}
in_countries = false
block = nil
tag = nil
File.foreach(gamestate, encoding: "binary") do |raw|
  line = raw.force_encoding("windows-1252").encode("UTF-8", invalid: :replace, undef: :replace).chomp
  if !in_countries
    in_countries = true if line == "countries={"
    next
  end
  if block
    if line == "\t}"
      countries[tag] = parse_country(block)
      block = nil
    else
      block << line
    end
  elsif (m = line.match(/\A\t([A-Z0-9]{3})=\{\z/))
    tag = m[1]
    block = []
  elsif line == "}" # the end of countries={}
    break
  end
end
FileUtils.rm_rf(dir)

# --- Shape the output -------------------------------------------------------------------------------------------
def prov_name(id) = NAMES["PROV#{id}"] || "Province #{id}"

out = {}
used_units = {}
countries.each do |t, c|
  next if t == "REB" # the rebels
  next unless c[:development].to_f.positive? || c[:armies].any? || c[:navies].any?

  regs = Hash.new(0)
  c[:armies].each { |a| a[:regiments].each { |k, n| regs[k] += n } }
  ships = Hash.new(0)
  c[:navies].each { |a| a[:ships].each { |k, n| ships[k] += n } }
  (regs.keys + ships.keys + (c[:best] || {}).values).each { |k| used_units[k] = true }
  tab = c[:income_table]
  out[t] = {
    regiments: regs, ships: ships,
    armies: c[:armies].map { |a| { name: a[:name], at: a[:location] && prov_name(a[:location]), n: a[:regiments].values.sum } },
    fleets: c[:navies].map { |a| { name: a[:name], at: a[:location] && prov_name(a[:location]), n: a[:ships].values.sum } },
    manpower: c[:manpower], max_manpower: c[:max_manpower], sailors: c[:sailors]&.round, max_sailors: c[:max_sailors]&.round,
    treasury: c[:treasury]&.round(1), income: c[:income]&.round(2), expense: c[:expense]&.round(2),
    tax: tab[0]&.round(2), production: tab[1]&.round(2), trade: tab[2]&.round(2), other_income: (tab[3..] || []).sum.round(2),
    army_tradition: c[:army_tradition]&.round(1), navy_tradition: c[:navy_tradition]&.round(1), prestige: c[:prestige]&.round(1),
    stability: c[:stability], legitimacy: c[:legitimacy]&.round(1), tech: c[:tech], best: c[:best], loan_size: c[:loan_size]
  }.compact
end

units = used_units.keys.to_h { |k| [ k, unit_info[k] || { name: NAMES[k] || k.tr("_", " "), kind: nil } ] }
File.write(OUT, JSON.generate(date: date, player: player, dlc: dlc, units: units, countries: out))
puts "Wrote forces.json: #{out.size} countries from a save of #{date} (player #{player}; DLC: #{dlc.join(', ')})"
puts "With armies: #{out.count { |_, c| c[:regiments].any? }}, with fleets: #{out.count { |_, c| c[:ships].any? }}, total regiments #{out.values.sum { |c| c[:regiments].values.sum }}, ships #{out.values.sum { |c| c[:ships].values.sum }}"
puts "ENG: #{out['ENG'].to_json[0, 600]}"
