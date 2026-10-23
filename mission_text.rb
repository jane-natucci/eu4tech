# Turns a mission's `trigger` (what you must do) and `effect` (what you get) scripts into readable
# lines for eu4tech. The game builds those tooltips in code, so there is no text file to copy: the
# common triggers and effects are worded here, `custom_tooltip` / `custom_trigger_tooltip` use the
# game's own text, and anything not recognised is shown with its script name humanised, so nothing
# is silently dropped.
#
# A line is a String, or [String, [children]] for a line with a list under it.
class MissionText
  attr_reader :unknown

  # parse helpers (get/all) come from extract_countries.rb; the game's text and a few tables come in here.
  def initialize(names:, mods:, areas:, countries:, label:)
    @names = names           # localisation
    @mods = mods             # event modifier name => [[key, number], ...]
    @areas = areas           # area / region / superregion / continent keys
    @countries = countries   # tags we know
    @label = label           # ->(modifier key) => text
    @unknown = Hash.new(0)
  end

  def conditions(block) = lines(items(block || [], :trigger))
  def rewards(block) = lines(items(block || [], :effect))

  private

  # --- plumbing -----------------------------------------------------------------------------------
  def lines(list) = list.compact.reject { |x| x == "" }

  # A scripted value that isn't a block (a bare name or number) has nothing to look inside.
  def g(block, key) = block.is_a?(Array) ? block.find { |k, _| k == key }&.last : nil

  # One script entry can word as nothing, one line, a line with a list under it, or several lines (Many).
  Many = Struct.new(:list)

  def items(block, mode)
    return [] unless block.is_a?(Array)

    out = []
    skipped_if = false # an `if` whose condition and body worded as nothing: its `else` then stands alone
    block.each do |k, v|
      if %w[else else_if].include?(k) && skipped_if && v.is_a?(Array)
        r = k == "else" ? Many.new(items(v.reject { |kk, _| kk == "limit" }, mode)) : conditional("if", v, mode)
      else
        r = item(k, v, mode)
      end
      skipped_if = %w[if else_if].include?(k) ? r.nil? : (k == "else" ? false : skipped_if)
      out.concat(r.is_a?(Many) ? r.list : [ r ])
    end
    out.compact
  end

  def group(title, kids)
    kids = kids.compact
    return nil if kids.empty?

    [ title, kids ]
  end

  def name(key) = @names[key.to_s]&.gsub(/§[A-Za-z!]/, "")&.gsub(/\$[^$]*\$/, "")&.gsub(/\[[^\]]*\]/, "")&.gsub(/£\w+£?/, "")&.gsub(/@[A-Z0-9]{3}\s?/, "")&.gsub('\n', " ")&.gsub(/\s+/, " ")&.strip
  def human(key) = key.to_s.tr("_", " ").sub(/\A./, &:upcase)
  def label(key) = name(key) || human(key)
  def country(tag) = tag == "ROOT" ? "this country" : (name(tag) || tag.to_s)
  def province(id) = name("PROV#{id}") || "province #{id}"
  def num(v) = v.to_s.match?(/\A-?\d+\.0+\z/) ? v.to_s.to_f.to_i.to_s : v.to_s
  def pct(v) = "#{(v.to_f * 100).round(1).to_s.sub(/\.0\z/, '')}%"
  def years(days) = days.to_i == -1 ? "permanently" : (days.to_i >= 365 ? "for #{(days.to_i / 365.0).round(1).to_s.sub(/\.0\z/, '')} years" : "for #{days.to_i} days")
  def place?(key) = @areas.include?(key.to_s)
  def numeric?(v) = v.is_a?(String) && v.match?(/\A-?\d*\.?\d+\z/)
  def province_id?(key) = key.to_s.match?(/\A\d+\z/)

  # --- shared by triggers and effects ------------------------------------------------------------------
  def item(k, v, mode)
    return nil if k.nil?
    return nil if k.include?(":") || %w[FROM PREV THIS FROMFROM PREVPREV].include?(k) || k.start_with?("country_event")
    return Many.new(items(v, mode)) if k == "ROOT" && v.is_a?(Array)
    return scope_of_country(k, v, mode) if v.is_a?(Array) && @countries.include?(k)
    return place_or_province_scope(k, v, mode) if (place?(k) || province_id?(k)) && v.is_a?(Array)
    return mode == :trigger ? trigger_item(k, v) : effect_item(k, v)
  end

  def conditional(k, v, mode)
    return nil unless v.is_a?(Array)

    limit = g(v, "limit")
    body = v.reject { |kk, _| kk == "limit" }
    kids = items(body, mode)
    head = case k
           when "if" then limit ? "If #{inline(limit)}:" : "Otherwise:"
           when "else_if" then limit ? "Otherwise, if #{inline(limit)}:" : "Otherwise:"
           else "Otherwise:"
           end
    group(head, kids)
  end

  # A short condition on one line ("it owns Paris and is Catholic"), or a count if it is long.
  def inline(block)
    parts = items(block, :trigger).map { |x| x.is_a?(Array) ? x.first.sub(/:\z/, "") : x }
    return "the situation described applies" if parts.empty?

    parts.size > 3 ? "#{parts.first(3).join(', ')} and #{parts.size - 3} more conditions" : parts.join(", ")
  end

  def scope_of_country(tag, v, mode)
    group("#{country(tag)}:", items(v, mode))
  end

  def place_or_province_scope(k, v, mode)
    where = province_id?(k) ? province(k) : label(k)
    if mode == :trigger
      all_of = g(v, "type") == "all"
      holds = g(v, "country_or_non_sovereign_subject_holds") == "ROOT"
      owned = g(v, "owned_by") == "ROOT"
      rest = v.reject { |kk, _| %w[type value country_or_non_sovereign_subject_holds owned_by].include?(kk) }
      if (holds || owned) && rest.empty?
        n = g(v, "value")
        return n ? "Own #{holds ? 'or have a subject own ' : ''}at least #{num(n)} provinces in #{where}" : "Own #{holds ? '(or have a subject own) ' : ''}#{all_of ? 'all of' : 'a province in'} #{where}"
      end
      kids = items(rest, :trigger) + (holds || owned ? [ "Own #{holds ? 'or have a subject own ' : ''}#{all_of ? 'all of them' : 'them'}" ] : [])
      group("In #{where}#{all_of ? ' (every province)' : ''}:", kids)
    else
      body = v.reject { |kk, _| kk == "limit" }
      claim = g(body, "add_permanent_claim") == "ROOT"
      only = body.reject { |kk, _| kk == "add_permanent_claim" }
      if claim && only.empty?
        "Gain permanent claims on #{where}#{g(v, 'limit') ? ' (provinces you do not own or have cored)' : ''}"
      else
        group("In #{where}#{g(v, 'limit') ? ' (where it applies)' : ''}:", items(only, :effect) + (claim ? [ "Gain permanent claims" ] : []))
      end
    end
  end

  # --- triggers ---------------------------------------------------------------------------------------------
  # Plain "at least N" tests on the country.
  AT_LEAST = {
    "development" => "Total development of at least %s", "total_development" => "Total development (with subjects) of at least %s",
    "army_size" => "An army of at least %s regiments", "navy_size" => "A navy of at least %s ships", "stability" => "Stability of at least %s",
    "prestige" => "Prestige of at least %s", "legitimacy" => "Legitimacy of at least %s", "treasury" => "At least %s ducats in the treasury",
    "num_of_cities" => "At least %s cities", "num_of_ports" => "At least %s ports", "num_of_allies" => "At least %s allies",
    "num_of_colonies" => "At least %s colonies", "num_of_provinces" => "At least %s provinces", "adm_tech" => "Administrative technology level %s",
    "dip_tech" => "Diplomatic technology level %s", "mil_tech" => "Military technology level %s", "army_tradition" => "Army tradition of at least %s",
    "navy_tradition" => "Navy tradition of at least %s", "manpower" => "At least %s thousand manpower", "sailors" => "At least %s sailors",
    "monthly_income" => "A monthly income of at least %s ducats", "num_of_merchants" => "At least %s merchants", "num_of_diplomats" => "At least %s diplomats",
    "num_of_vassals" => "At least %s vassals", "num_of_subjects" => "At least %s subjects", "average_autonomy" => "Average autonomy of at most %s%%",
    "inflation" => "Inflation of at most %s", "war_exhaustion" => "War exhaustion of at most %s", "innovativeness" => "Innovativeness of at least %s",
    "num_of_unions" => "At least %s personal unions", "overextension_percentage" => "Overextension of at most %s", "num_of_mercenaries" => "At least %s mercenary regiments",
    "num_of_marches" => "At least %s marches", "num_of_heavy_ship" => "At least %s heavy ships", "num_of_light_ship" => "At least %s light ships",
    "num_of_galley" => "At least %s galleys", "num_of_transport" => "At least %s transports", "num_of_free_cities" => "At least %s free cities",
    "corruption" => "Corruption of at most %s", "num_of_total_ports" => "At least %s ports", "absolutism" => "Absolutism of at least %s",
    "devotion" => "Devotion of at least %s", "horde_unity" => "Horde unity of at least %s", "republican_tradition" => "Republican tradition of at least %s",
    "meritocracy" => "Meritocracy of at least %s", "army_professionalism" => "Army professionalism of at least %s", "religious_unity" => "Religious unity of at least %s",
    "navy_size_percentage" => "A navy at %s of its force limit", "army_size_percentage" => "An army at %s of its force limit",
    "hre_size" => "The Holy Roman Empire has at least %s members", "crown_land_share" => "Crown land at least %s%%",
    "num_ships_protecting_trade" => "At least %s ships protecting trade", "num_of_rebel_armies" => "At least %s rebel armies",
    "num_of_regions" => "Provinces in at least %s regions", "num_of_continents" => "Provinces on at least %s continents"
  }.freeze

  # Tests whose value is a name.
  NAMED = {
    "religion" => ["State religion: %s", :label], "religion_group" => ["Religion group: %s", :label], "primary_culture" => ["Primary culture: %s", :label],
    "culture_group" => ["Culture group: %s", :label], "government" => ["Government: %s", :label], "has_reform" => ["Has the reform %s", :label],
    "is_subject_of" => ["Is a subject of %s", :country], "alliance_with" => ["Allied with %s", :country], "exists" => ["%s exists", :country],
    "tag" => ["Is %s", :country], "is_rival" => ["Has %s as a rival", :country], "is_enemy" => ["At war with %s", :country], "war_with" => ["At war with %s", :country],
    "has_discovered" => ["Has discovered %s", :label], "full_idea_group" => ["Has finished the %s idea group", :label], "has_idea_group" => ["Has the %s idea group", :label],
    "has_idea" => ["Has the idea %s", :label], "has_estate" => ["Has the %s estate", :label], "has_estate_privilege" => ["Has the privilege %s", :label],
    "is_subject_of_type" => ["Is a %s", :label], "has_government_attribute" => ["Government can %s", :human], "technology_group" => ["Technology group: %s", :label],
    "has_building" => ["Has a %s", :label], "trade_goods" => ["Produces %s", :label], "continent" => ["On the continent %s", :label],
    "has_ruler_flag" => nil, "has_country_flag" => nil, "has_global_flag" => nil, "has_dlc" => nil, "always" => nil, "not_in_mission_preview_mode" => nil,
    "is_ai" => nil, "has_country_modifier" => ["Has the modifier %s", :label], "owns" => ["Owns %s", :province], "owns_core_province" => ["Owns and has a core on %s", :province],
    "owns_or_non_sovereign_subject_of" => ["Owns (or a subject owns) %s", :province], "is_core" => ["Is a core of %s", :country], "province_id" => ["Is %s", :province],
    "has_institution" => ["Has embraced the %s institution", :label], "mission_completed" => ["Has completed the mission %s", :mission],
    "has_great_project" => ["Owns the great project %s", :label], "accepted_culture" => ["Accepts the %s culture", :label], "culture" => ["Culture: %s", :label],
    "has_saved_event_target" => nil, "has_global_event_target" => nil, "has_manufactory_trigger" => ["Has a manufactory", :flag], "is_emperor_of_china" => ["Is Emperor of China", :flag],
    "has_port" => ["Has a port", :flag], "is_capital" => ["Is the capital", :flag], "is_city" => ["Is a city", :flag], "is_emperor" => ["Is the Emperor of the Holy Roman Empire", :flag],
    "is_elector" => ["Is an elector", :flag], "is_free_or_tributary_trigger" => ["Is independent or a tributary", :flag], "is_subject" => ["Is a subject", :flag],
    "is_at_war" => ["Is at war", :flag], "is_great_power" => ["Is a great power", :flag], "has_regency" => ["Has a regent", :flag], "is_defender_of_faith" => ["Is Defender of the Faith", :flag],
    "is_papal_controller" => ["Controls the Papacy", :flag], "has_female_heir" => ["Has a female heir", :flag], "is_female" => ["Ruler is a woman", :flag], "is_lesser_in_union" => ["Is the junior partner in a union", :flag],
    "is_colonial_nation" => ["Is a colonial nation", :flag], "is_part_of_hre" => ["Is part of the Holy Roman Empire", :flag], "is_tribal" => ["Has a tribal government", :flag]
  }.freeze

  def named(spec, v)
    text, kind = spec
    return nil unless text

    value = case kind
            when :label then label(v)
            when :country then country(v)
            when :province then province(v)
            when :human then human(v)
            when :mission then name("#{v}_title") || human(v)
            when :flag then (v == "no" ? nil : true)
            end
    return nil if value.nil?
    return kind == :flag && v == "no" ? text.sub(/\AIs /, "Is not ").sub(/\AHas /, "Has no ") : text if kind == :flag

    text % value
  end

  def trigger_item(k, v)
    case k
    when "custom_trigger_tooltip"
      t = g(v, "tooltip")
      name(t) || nil
    when "tooltip", "custom_tooltip" then name(v)
    when "OR" then any_of(v)
    when "AND" then flat_or_group(nil, v, :trigger)
    when "NOT", "NOR" then negation(v)
    when "if", "else_if", "else" then conditional(k, v, :trigger)
    when "calc_true_if" then calc_true(v)
    when "capital_scope" then group("Its capital:", items(v, :trigger))
    when "any_country", "any_known_country", "any_neighbor_country", "any_ally", "any_subject_country", "any_rival_country", "any_enemy_country" then group("#{human(k.sub('any_', '').sub('_country', ''))} country with:", items(v, :trigger))
    when "any_owned_province", "any_province" then group("An owned province with:", items(v, :trigger))
    when "all_owned_province", "all_province" then group("Every owned province has:", items(v, :trigger))
    when "num_of_owned_provinces_with", "num_of_provinces_owned_or_owned_by_non_sovereign_subjects_with"
      n = g(v, "value") || "1"
      filters = v.reject { |kk, _| kk == "value" }
      subject = k.include?("non_sovereign") ? " (or have subjects own)" : ""
      group("Own#{subject} at least #{num(n)} provinces with:", items(filters, :trigger))
    when "trade_share" then v.is_a?(Array) ? "Trade share of at least #{num(g(v, 'share') || g(v, 'value'))}%" : nil
    when "is_strongest_trade_power" then "Strongest trade power in #{label(v)}"
    when "has_opinion" then "Opinion of #{country(g(v, 'who'))} at least #{num(g(v, 'value'))}"
    when "estate_loyalty" then "#{label(g(v, 'estate'))} loyalty at least #{num(g(v, 'loyalty'))}%"
    when "estate_influence" then "#{label(g(v, 'estate'))} influence at least #{num(g(v, 'influence'))}%"
    when "num_of_estate_privileges" then "At least #{num(g(v, 'value'))} #{label(g(v, 'estate'))} privileges"
    when "has_tax_building_trigger" then "Has a tax building"
    when "has_production_building_trigger" then "Has a production building"
    when "has_trade_building_trigger" then "Has a trade building"
    when "has_manpower_building_trigger" then "Has a manpower building"
    when "current_age" then "In the #{label(v)}"
    when "num_of_times_improved" then "Improved at least #{num(v)} times"
    when "total_own_and_non_tributary_subject_development" then "Total development (with subjects) of at least #{num(v)}"
    when "province_has_center_of_trade_of_level" then "A level #{num(v)} center of trade"
    when "area", "region", "superregion" then area_trigger(k, v)
    when "has_building" then v.is_a?(String) ? "Has a #{label(v)}" : nil
    when "has_country_flag", "has_global_flag", "has_ruler_flag", "has_dlc", "always", "not_in_mission_preview_mode", "is_ai", "has_heir_flag", "had_country_flag" then nil
    else
      if AT_LEAST.key?(k) && (numeric?(v) || v.is_a?(Array))
        value = v.is_a?(Array) ? g(v, "value") : v
        value = pct(value) if k.end_with?("_size_percentage")
        return AT_LEAST[k] % num(value)
      end
      if NAMED.key?(k)
        return named(NAMED[k], v) if NAMED[k] && v.is_a?(String)
        return nil
      end
      fallback(k, v, :trigger)
    end
  end

  def area_trigger(k, v)
    return "In #{label(v)}" if v.is_a?(String)

    where = label(g(v, k) || g(v, "area") || "")
    group("In #{where}:", items(v.reject { |kk, _| kk == k }, :trigger))
  end

  def any_of(v)
    kids = items(v, :trigger)
    return nil if kids.empty?
    return kids.first if kids.size == 1

    [ "Any of:", kids ]
  end

  def flat_or_group(title, v, mode)
    kids = items(v, mode)
    kids.size == 1 ? kids.first : (title ? group(title, kids) : Many.new(kids))
  end

  def negation(v)
    if v.is_a?(Array) && v.size == 1 && v.first.first
      k, val = v.first
      return "#{country(val)} doesn't exist" if k == "exists"
      return "Not allied with #{country(val)}" if k == "alliance_with"
      return "Not a subject of #{country(val)}" if k == "is_subject_of"
      return "Not at war with #{country(val)}" if k == "war_with"
      return "Not a subject" if k == "is_subject" && val == "yes"
    end
    kids = items(v, :trigger)
    return nil if kids.empty?
    return [ "None of:", kids ] if kids.size > 1

    kid = kids.first
    kid.is_a?(String) ? "Not: #{kid.sub(/\A./, &:downcase)}" : [ "None of:", kids ]
  end

  def calc_true(v)
    amount = g(v, "amount")
    kids = items(v.reject { |kk, _| %w[amount desc].include?(kk) }, :trigger)
    desc = name(g(v, "desc"))
    return desc if desc && kids.empty?

    group("At least #{num(amount || 1)} of:", kids)
  end

  # --- effects -------------------------------------------------------------------------------------------------
  GAIN = {
    "add_prestige" => "%s prestige", "add_adm_power" => "%s administrative power", "add_dip_power" => "%s diplomatic power", "add_mil_power" => "%s military power",
    "add_stability" => "%s stability", "add_legitimacy" => "%s legitimacy", "add_mercantilism" => "%s mercantilism", "add_army_tradition" => "%s army tradition",
    "add_navy_tradition" => "%s navy tradition", "add_treasury" => "%s ducats", "add_manpower" => "%s thousand manpower", "add_sailors" => "%s sailors",
    "add_devotion" => "%s devotion", "add_papal_influence" => "%s papal influence", "add_meritocracy" => "%s meritocracy", "add_republican_tradition" => "%s republican tradition",
    "add_absolutism" => "%s absolutism", "add_war_exhaustion" => "%s war exhaustion", "add_horde_unity" => "%s horde unity", "add_inflation" => "%s inflation",
    "add_corruption" => "%s corruption", "change_innovativeness" => "%s innovativeness", "add_army_professionalism" => "%s army professionalism",
    "add_base_tax" => "%s base tax", "add_base_production" => "%s base production", "add_base_manpower" => "%s base manpower", "add_local_autonomy" => "%s local autonomy",
    "add_unrest" => "%s unrest", "add_devastation" => "%s devastation", "add_province_triggered_modifier" => nil, "add_authority" => "%s authority", "add_karma" => "%s karma",
    "add_harmony" => "%s harmony", "add_piety" => "%s piety", "add_yearly_manpower" => "%s years of manpower", "add_years_of_income" => "%s years of income",
    "add_splendor" => "%s splendor", "add_treasury_percent" => nil, "add_trade_power" => nil, "add_isolationism" => "%s isolationism", "add_power_projection" => nil
  }.freeze

  HIDDEN_EFFECTS = %w[insight_tooltip country_event_with_insight country_event_with_option_insight country_event_with_effect_insight ai option_1 option_2 set_country_flag clr_country_flag set_global_flag clr_global_flag set_ruler_flag clr_ruler_flag hidden_effect country_event set_variable change_variable
                      set_province_flag clr_province_flag save_event_target_as save_global_event_target_as add_ruler_personality remove_ruler_personality tooltip start_mission_cooldown
                      set_heir_flag clr_heir_flag clear_scripted_personalities ai_will_do].freeze

  def effect_item(k, v)
    return nil if HIDDEN_EFFECTS.include?(k)

    case k
    when "custom_tooltip" then name(v)
    when "simple_dynamic_effect", "complex_dynamic_effect" then dynamic_tooltips(v)
    when "if", "else_if", "else" then conditional(k, v, :effect)
    when "add_country_modifier", "add_province_modifier", "add_trade_modifier", "add_ruler_modifier" then modifier_effect(k, v)
    when "add_permanent_claim", "add_claim" then v == "ROOT" ? nil : "Gain a #{k.end_with?('permanent_claim') ? 'permanent ' : ''}claim on #{v.to_s.match?(/\A\d+\z/) ? province(v) : label(v)}"
    when "give_claims" then "Gain claims on #{label(g(v, 'id') || 'a province')}"
    when "add_historical_friend" then "#{country(v)} becomes a historical friend"
    when "add_historical_rival" then "#{country(v)} becomes a historical rival"
    when "add_casus_belli", "reverse_add_casus_belli"
      cb = g(v, "type")
      months = g(v, "months")
      "#{k.start_with?('reverse') ? 'Give ' + country(g(v, 'target')) + ' a' : 'Gain a'} #{label(cb)} casus belli#{k.start_with?('reverse') ? '' : ' against ' + country(g(v, 'target'))}#{months ? " for #{num(months)} months" : ''}"
    when "define_advisor"
      type = label(g(v, "type"))
      skill = g(v, "skill")
      discount = g(v, "cost_multiplier")
      "Gain a#{skill ? " level #{num(skill)}" : 'n'} #{type.downcase} advisor#{discount ? " (cost #{pct(1 - discount.to_f)} lower)" : ''}"
    when "change_ruler_stat"
      "#{g(v, 'amount').to_f.positive? ? '+' : ''}#{num(g(v, 'amount'))} #{label(g(v, 'type'))} ruler skill"
    when "add_stability_or_adm_power" then name("add_stability_or_adm_power_tt") || "Gain stability, or administrative power if it is already at its maximum"
    when "add_prestige_or_monarch_power" then "Gain prestige or monarch power"
    when "add_estate_loyalty" then "#{label(g(v, 'estate'))} loyalty #{g(v, 'loyalty').to_f.positive? ? '+' : ''}#{num(g(v, 'loyalty'))}%"
    when "add_estate_influence_modifier" then "#{label(g(v, 'estate'))} influence modifier"
    when "change_government_reform_progress" then "#{num(v)} reform progress"
    when "every_owned_province", "random_owned_province", "every_province", "random_province", "random_neighbor_province" then each_province(k, v)
    when "capital_scope" then group("In the capital:", items(v, :effect))
    when "remove_country_modifier" then "Lose the modifier #{label(v)}"
    when "unlock_estate_privilege" then "Unlock the privilege #{label(g(v, 'estate_privilege') || v)}"
    when "add_core" then v == "ROOT" ? "Gain a core" : "Gain a core on #{v}"
    when "add_building" then "Build a #{label(v)}"
    when "create_subject" then "Create a subject: #{country(g(v, 'who') || g(v, 'subject_type'))}"
    when "release" then "Release #{country(v)}"
    when "add_trust", "add_opinion" then nil
    else
      if GAIN.key?(k)
        return GAIN[k] ? (GAIN[k] % signed(v)) : nil if numeric?(v)
      end
      fallback(k, v, :effect)
    end
  end

  # The game words these itself: its tooltip texts are the readable part (the effects inside depend on the situation).
  def dynamic_tooltips(v)
    texts = v.filter_map { |kk, vv| name(vv) if kk&.end_with?("custom_tooltip") }
    texts.empty? ? nil : Many.new(texts)
  end

  def signed(v) = "#{v.to_s.start_with?('-') ? '' : '+'}#{num(v)}"

  def each_province(k, v)
    limit = g(v, "limit")
    kids = items(v.reject { |kk, _| kk == "limit" }, :effect)
    which = case k
            when "every_owned_province" then "Every owned province"
            when "random_owned_province" then "A random owned province"
            when "every_province" then "Every province"
            when "random_province" then "A random province"
            else "A random neighboring province"
            end
    group("#{which}#{limit ? " (#{inline(limit)})" : ''}:", kids)
  end

  def modifier_effect(k, v)
    mod = v.is_a?(Array) ? g(v, "name") : v
    duration = v.is_a?(Array) ? g(v, "duration") : nil
    scope = { "add_province_modifier" => "in the province", "add_trade_modifier" => "on trade" }[k]
    head = "Modifier: #{label(mod)}#{scope ? " (#{scope})" : ''}#{duration ? " (#{years(duration)})" : ''}"
    effects = (@mods[mod] || []).filter_map { |key, value| (text = @label.call(key, value)) && text }
    effects.empty? ? head : [ head, effects ]
  end

  # --- anything else: show it, humanised, so a mission never silently loses a requirement ----------------------
  def pretty(v) = v == "ROOT" ? "this country" : (@countries.include?(v) ? country(v) : (@names[v.to_s] && !numeric?(v) ? label(v) : v.to_s))

  def fallback(k, v, mode)
    @unknown[k] += 1
    if v.is_a?(Array) && !v.empty? && v.all? { |kk, vv| kk && !vv.is_a?(Array) }
      params = v.map { |kk, vv| "#{human(kk).downcase} #{pretty(vv)}" }.join(", ")
      "#{human(k)} (#{params})"
    elsif v.is_a?(Array)
      kids = items(v, mode)
      kids.empty? ? nil : [ "#{human(k)}:", kids ]
    elsif %w[yes no].include?(v)
      v == "yes" ? human(k) : "Not: #{human(k).downcase}"
    else
      "#{human(k)}: #{pretty(v)}"
    end
  end
end
