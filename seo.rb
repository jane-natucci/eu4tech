# The crawlable side of the site, generated at deploy time from the data files: one real page per significant
# country (its own title, description, canonical address, structured data and a plain-text summary of how it
# starts), a sitemap, and the front page. The page itself is one app; these pages are the same app opened on a
# country at the first start where it exists, so a search for "Castile EU4 1444" can land on Castile.
#
#   ruby seo.rb <countries.json> <ideas.json> <missions.json> <index.html as deployed> <output dir>
#
# The data files may be gzipped (as they are on the site). Writes <output dir>/index.html, <output dir>/country/<slug>
# (no extension: the deploy uploads them as text/html) and <output dir>/sitemap.xml. Standard library only.
require "json"
require "cgi"
require "zlib"
require "stringio"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8 # a CI runner may not have a UTF-8 locale
Encoding.default_internal = nil

SITE = "https://eu4tech.jane.berlin"
GAME = "Europa Universalis IV"
SHORT = "EU4"
MIN_PROVINCES = 5 # countries smaller than this get no page of their own: there'd be little to say about them

def load_json(path)
  raw = File.binread(path)
  raw = Zlib::GzipReader.new(StringIO.new(raw)).read if raw.start_with?("\x1F\x8B".b)
  JSON.parse(raw.force_encoding("UTF-8"))
end

countries_data = load_json(ARGV[0])
ideas = load_json(ARGV[1])["by_tag"]
missions = load_json(ARGV[2])["by_tag"]
template = File.read(ARGV[3], encoding: "UTF-8")
out = ARGV[4]
dates = countries_data["dates"]
terms = countries_data["names"] # government, religion, culture ... keys -> the game's words for them
names = countries_data["countries"].to_h { |c| [ c["tag"], c["name"] ] }

def h(text) = CGI.escapeHTML(text.to_s)
def n0(x) = x.to_f.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
def slugify(name) = name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
def humanize(key) = key.to_s.tr("_", " ").capitalize
def term(terms, key) = terms[key.to_s] || humanize(key)
def count(n, one, many = "#{one}s") = "#{n0(n)} #{n.to_i == 1 ? one : many}"
def development(at) = at["tax"].to_i + at["prod"].to_i + at["man"].to_i

# The earliest start where each country exists, and its numbers then.
pages = countries_data["countries"].filter_map do |c|
  date = dates.find { |d| c["at"][d] }
  next unless date

  at = c["at"][date]
  next if at["provinces"].to_i < MIN_PROVINCES

  { "tag" => c["tag"], "name" => c["name"], "date" => date, "at" => at }
end.sort_by { |c| [ -development(c["at"]), c["name"] ] }
used = {}
pages.each do |c|
  slug = slugify(c["name"])
  slug = "#{slug}-#{c["tag"].downcase}" if slug.empty? || used.key?(slug)
  used[slug] = c
  c["slug"] = slug
end
rank_of = pages.each_with_index.to_h { |c, i| [ c["tag"], i + 1 ] }

def person(p, role)
  return nil unless p

  who = "#{role}: #{p["name"]}#{p["dynasty"] ? " #{p["dynasty"]}" : ""}"
  who += ", born #{p["born"]}" if p["born"]
  who += ", administration #{p["adm"]}, diplomacy #{p["dip"]}, military #{p["mil"]}" if p["adm"]
  who
end

def tags_to_names(tags, names, limit = 8) = tags.first(limit).map { |t| names[t] || t }.join(", ")

def summary(c, names, terms, ideas, missions)
  at = c["at"]
  year = c["date"].split(".").first
  idea = ideas[c["tag"]]
  trees = missions[c["tag"]]
  facts = []
  facts << "#{c["name"]} (#{c["tag"]}) at the #{year} start of #{GAME} (#{c["date"]}): a #{[ at["government"], at["religion"], at["culture"] ].compact.map { |x| term(terms, x) }.join(", ")} country " \
           "of #{count(at["provinces"], "province")}#{at["capital"] ? ", capital #{at["capital"]}" : ""}."
  facts << "Its development is #{n0(development(at))} (tax #{n0(at["tax"])}, production #{n0(at["prod"])}, manpower #{n0(at["man"])})#{at["tech_group"] ? " and it is in the #{term(terms, at["tech_group"])} technology group" : ""}."
  facts << "#{person(at["ruler"], "Ruler")}." if at["ruler"]
  facts << "#{person(at["heir"], "Heir")}." if at["heir"]
  facts << "Rivals: #{tags_to_names(at["rivals"], names)}." if at["rivals"]&.any?
  facts << "Allies: #{tags_to_names(at["allies"], names)}." if at["allies"]&.any?
  facts << "Subjects: #{at["subjects"].first(8).map { |s| "#{names[s["tag"]] || s["tag"]} (#{term(terms, s["type"])})" }.join(", ")}." if at["subjects"]&.any?
  if idea
    firsts = idea["ideas"].first(4).map { |i| i["name"] }
    facts << "National ideas: #{idea["name"]}#{firsts.any? ? " (#{firsts.join(", ")} ...)" : ""}."
  end
  facts << "It has #{count(trees.size, "mission tree")} to follow." if trees.is_a?(Array) && trees.any?
  facts
end

def description(c)
  at = c["at"]
  who = at["ruler"] ? ", ruled by #{at["ruler"]["name"]}" : ""
  "#{c["name"]} at the #{c["date"].split(".").first} start of #{GAME}#{who}: #{count(at["provinces"], "province")}, #{n0(development(at))} development, its national ideas, missions, rivals and allies."[0, 300]
end

# --- Rewrites of the page's own tags ---------------------------------------------------------------------------------
def retag(html, title:, description:, url:)
  html = html.sub(%r{<title>.*?</title>}m, "<title>#{h(title)}</title>")
  html = html.sub(/(<meta name="description" content=")[^"]*(")/, "\\1#{h(description)}\\2")
  html = html.sub(/(<link rel="canonical" href=")[^"]*(")/, "\\1#{url}\\2")
  html = html.sub(/(<meta property="og:url" content=")[^"]*(")/, "\\1#{url}\\2")
  html = html.gsub(/(<meta (?:property="og:title"|name="twitter:title") content=")[^"]*(")/, "\\1#{h(title)}\\2")
  html.gsub(/(<meta (?:property="og:description"|name="twitter:description") content=")[^"]*(")/, "\\1#{h(description)}\\2")
end

def ld(obj) = %(<script type="application/ld+json">#{JSON.generate(obj).gsub("</", "<\\/")}</script>)

links_to = lambda do |list|
  list.map { |c| %(<a href="/country/#{c["slug"]}">#{h(c["name"])}</a>) }.join(" · ")
end

# --- A page per country ----------------------------------------------------------------------------------------------
FileUtils.mkdir_p(File.join(out, "country"))
pages.each do |c|
  i = rank_of[c["tag"]] - 1
  near = (pages[[ i - 6, 0 ].max...i] + pages[(i + 1)..(i + 6)].to_a)
  year = c["date"].split(".").first
  block = <<~HTML
    <details class="seo-about">
      <summary>About #{h(c["name"])} at the #{year} start</summary>
      #{summary(c, names, terms, ideas, missions).map { |f| "<p>#{h(f)}</p>" }.join("\n      ")}
      <p>Similar in size: #{links_to.call(near)}. <a href="/">All countries</a>.</p>
    </details>
  HTML
  title = "#{c["name"]} in #{SHORT} (#{year}): ruler, national ideas, missions and economy – #{SHORT} Tech"
  url = "#{SITE}/country/#{c["slug"]}"
  html = retag(template, title: title, description: description(c), url: url)
  html = html.sub("<!--seo:about-->", block)
  html = html.sub("<!--seo:head-->", %(<meta name="initial-tag" content="#{c["tag"]}">\n  <meta name="initial-date" content="#{c["date"]}">\n  ) + ld({
    "@context" => "https://schema.org", "@type" => "WebPage", "name" => title, "url" => url,
    "description" => description(c), "inLanguage" => "en",
    "isPartOf" => { "@type" => "WebSite", "name" => "#{SHORT} Tech", "url" => "#{SITE}/" },
    "about" => { "@type" => "Thing", "name" => "#{c["name"]} in #{GAME}" },
    "breadcrumb" => { "@type" => "BreadcrumbList", "itemListElement" => [
      { "@type" => "ListItem", "position" => 1, "name" => "#{SHORT} Tech", "item" => "#{SITE}/" },
      { "@type" => "ListItem", "position" => 2, "name" => c["name"], "item" => url }
    ] }
  }))
  File.write(File.join(out, "country", c["slug"]), html, encoding: "UTF-8")
end

# --- The front page: unchanged to look at, just without the markers ---
File.write(File.join(out, "index.html"), template.sub("<!--seo:about-->", "").sub("<!--seo:head-->", ""), encoding: "UTF-8")

# --- Sitemap -------------------------------------------------------------------------------------------------------------
stamp = Time.parse(countries_data["generated_at"].to_s).utc.strftime("%Y-%m-%d") rescue Time.now.utc.strftime("%Y-%m-%d")
urls = [ [ "#{SITE}/", "1.0" ] ] + pages.map { |c| [ "#{SITE}/country/#{c["slug"]}", rank_of[c["tag"]] <= 30 ? "0.8" : "0.6" ] }
File.write(File.join(out, "sitemap.xml"), <<~XML, encoding: "UTF-8")
  <?xml version="1.0" encoding="UTF-8"?>
  <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  #{urls.map { |u, p| "  <url><loc>#{u}</loc><lastmod>#{stamp}</lastmod><priority>#{p}</priority></url>" }.join("\n")}
  </urlset>
XML
puts "SEO: #{pages.size} country pages, sitemap with #{urls.size} addresses"
