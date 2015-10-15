#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'net/https'
require 'nokogiri'
require 'uri'


$db = nil

PREFIX_WEIGHTS = {
    'Genre'             => 1.0,
    'Studio'            => 0.3,
    'Classification'    => 0.1,
    'Staff'             => 0.1,
    'Staff: Director'   => 1.0,
    'Staff: Script'     => 1.0,
    'Staff: Storyboard' => 0.7,
    'Staff: Screenplay' => 0.7,
    'Staff: Music'      => 1.0,
    'Staff: Sound Director' => 0.5,
    'Staff: Art Director'   => 1.0,
    'Staff: Key Animation'  => 0.3,
    'Staff: Episode Director'   => 1.0,
    'Staff: Animation Director' => 0.3,
    'Staff: Character Design'   => 0.7,
    'Staff: Series Composition' => 0.3,
    'Staff: Original Creator'   => 0.4,
    'Staff: Special Effects'    => 0.2,
    'Staff: Theme Song Composition'     => 0.3,
    'Staff: Original Character Design'  => 0.7,
    'Staff: Chief Animation Director'   => 0.2
}


def die(msg, exitcode=1)
    $stderr.puts(msg)
    IO.write('anilist.db', JSON.pretty_generate($db))
    exit exitcode
end


class AnilistSession
    def initialize(id, secret)
        @token = nil
        @token_info = post('auth/access_token',
                           { grant_type:    'client_credentials',
                             client_id:     id,
                             client_secret: secret })
        die('Invalid client ID/secret specified') unless @token_info
        @token = @token_info['access_token']
    end

    def post(where, what, url_params = {})
        url_params['access_token'] = @token if @token
        url_params = URI.encode_www_form(url_params)
        what = URI.encode_www_form(what)

        resp = Net::HTTP.start('anilist.co', use_ssl: true) do |http|
            http.post("https://anilist.co/api/#{where}?#{url_params}", what)
        end

        return nil unless resp.is_a?(Net::HTTPSuccess)

        return JSON.parse(resp.body)
    end

    def get(where, url_params = {})
        url_params['access_token'] = @token if @token
        url_params = URI.encode_www_form(url_params)

        resp = Net::HTTP.start('anilist.co', use_ssl: true) do |http|
            http.get("https://anilist.co/api/#{where}?#{url_params}")
        end

        return nil unless resp.is_a?(Net::HTTPSuccess)

        return JSON.parse(resp.body)
    end
end


class Array
    def average
        self.inject(:+) / self.length
    end

    def sd
        avg = self.average
        Math.sqrt(self.map { |v| (v - avg) ** 2 }.average)
    end
end


def simplified_role(role)
    if role.include?('(')
        i = 0
        i += 1 until role[i] == '('
        si = i
        nesting = 1
        while nesting > 0 && role[i]
            i += 1
            nesting += 1 if role[i] == '('
            nesting -= 1 if role[i] == ')'
        end
        s = role[0..(si-1)]
        e = role[(i+1)..-1]
        s = '' unless s
        e = '' unless e
        role = simplified_role(s.strip + ' ' + e.strip)
    end
    role.strip
end


def expanded_genres(anime, main_studio_handling)
    genres = anime['genres'].map { |g|
        "Genre: #{g}"
    } + anime['studio'].map { |s|
        if s['main_studio']
            if main_studio_handling == :double
                ["Studio: #{s['studio_name']}", "Studio: #{s['studio_name']} (main)"]
            elsif main_studio_handling == :extra
                ["Studio: #{s['studio_name']} (main)"]
            else
                ["Studio: #{s['studio_name']}"]
            end
        else
            ["Studio: #{s['studio_name']}"]
        end
    }.flatten + anime['staff'].map { |s|
        roles = (s['role'] ? simplified_role(s['role']) : '').split(',').map { |r| r.strip }
        if s['name_last'].empty? && s['name_first'].empty?
            roles = []
            name = nil
        elsif s['name_last'].empty?
            name = s['name_first']
        elsif s['name_first'].empty?
            name = s['name_last']
        else
            name = "#{s['name_last']}, #{s['name_first']}"
        end
        roles.map { |r|
            if r.empty?
                "Staff: #{name}"
            else
                "Staff: #{r}: #{name}"
            end
        }
    }.flatten
    genres << "Classification: #{anime['classification']}"

    return genres
end


def normalize_title(title)
    title.gsub(/\p{^Word}/, ' ').gsub(/\s+TV\s*$/, '').gsub(/\s+2nd\s+Season\s*$/, ' 2').gsub(/\s+wo\s+/, ' ')
end


def fetch_genres(user, sess)
    completed_list = sess.get("user/#{user}/animelist")['lists']['completed']

    die('Failed to fetch anime list') unless completed_list

    genre_votes = {}
    seen = []

    i = 0
    n = completed_list.length

    completed_list.each do |a|
        anime = sess.get("anime/#{a['anime']['id']}/page")
        seen << a['anime']['id'].to_i

        expanded_genres(anime, :duplicate).each do |genre|
            genre_votes[genre] = [] unless genre_votes[genre]
            genre_votes[genre] << a['score'].to_f
        end

        i += 1
        print "#{i}/#{n}\r"
        $stdout.flush
    end
    puts

    {
        genres: genre_votes.map { |g, v|
                [ g, v.length, v.average, v.sd ]
            }.sort { |gv1, gv2|
                gv2[2] <=> gv1[2]
            },

        seen: seen
    }
end

KNOWN_ID_ALIASES = {
    19285 => 19285,
    20039 => 20039,
    20423 => 20423,
    22297 => 19603, # F/SN: UBW (ufotable)
    23277 => 20657, # Saenai Heroine no Sodate-kata
    27821 => false, # Fate/stay night: Unlimited Blade Works (TV) - Prologue
    28701 => 20792, # F/SN: UBW (ufotable) 2nd Season
    29317 => false  # Saenai Heroine no Sodate-kata Episode 0
}

def fetch_genres_mal(user, sess)
    resp = Net::HTTP.start('myanimelist.net') do |http|
        http.get("http://myanimelist.net/malappinfo.php?status=all&type=anime&u=#{user}")
    end

    die('Failed to fetch anime list') unless resp.is_a?(Net::HTTPSuccess)

    full_list = Nokogiri::Slop(resp.body).myanimelist.anime

    genre_votes = {}
    seen = []

    i = 0
    n = full_list.length

    full_list.each do |a|
        if a.my_status.content == '2'
            id = a.series_animedb_id.content.to_i
            known_id = id < 19000 || (KNOWN_ID_ALIASES[id] != nil)
            if known_id && id >= 19000
                id = KNOWN_ID_ALIASES[id]
            end

            anime = nil

            anime = sess.get("anime/#{id}/page") if id
            if id && !known_id && (!anime || anime['title_romaji'] != a.series_title.content)
                title = normalize_title(a.series_title.content)
                begin
                    anime_list = sess.get("anime/search/#{URI.encode(title)}")
                rescue
                    die("Failed to find “#{title}”")
                end
                pal = anime_list.select do |ca|
                    [ca['title_romaji'], ca['title_english'], ca['title_japanese']].include?(a.series_title.content)
                end
                if pal.length < 1
                    pal = anime_list
                end
                anime = pal[0]
                die("Failed to find #{a.series_title.content}") unless anime
                puts "Auto-mapped “#{a.series_title.content}” -> “#{anime['title_romaji']}” / “#{anime['title_english']}”"
                id = anime['id'].to_i
                anime = sess.get("anime/#{id}/page")
            end

            if anime
                expanded_genres(anime, :duplicate).each do |genre|
                    genre_votes[genre] = [] unless genre_votes[genre]
                    genre_votes[genre] << a.my_score.content.to_f
                end

                seen << id
            end
        end

        i += 1
        print "#{i}/#{n}\r"
        $stdout.flush
    end
    puts

    {
        genres: genre_votes.map { |g, v|
                [ g, v.length, v.average, v.sd ]
            }.sort { |gv1, gv2|
                gv2[2] <=> gv1[2]
            },

        seen: seen
    }
end


options = ARGV.to_a.select { |o| o =~ /^--/ }
commands = ARGV.to_a - options

options.map! { |o|
    s = /^--([^=]+)=(.*)$/.match(o)
    if s
        [s[1], s[2]]
    else
        [o[2..-1], true]
    end
}
options = Hash[options]


begin
    $db = JSON.parse(IO.read('anilist.db'))
rescue
    $db = {}
end

$db['client-id'] = options['client-id'] if options['client-id']
$db['client-secret'] = options['client-secret'] if options['client-secret']

if options['user'] && options['user'] != $db['user']
    user_changed = true
    $db['user'] = options['user']
end

if options['help'] && !commands[0]
    commands[0] = 'help'
end

if commands[0] != 'help' && (!$db['client-id'] || !$db['client-secret'] || !$db['user'])
    die("You will want to specify client credentials and the user to fetch the scores from:\n  --client-id=<id> --client-secret=<secret> --user=<user>\n(See the “help” subcommand)")
end

sess = AnilistSession.new($db['client-id'], $db['client-secret']) unless commands[0] == 'help'

if commands[0] != 'help' && (!$db['genres'] || user_changed || options['refresh'])
    ret = nil
    if options['mal']
        ret = fetch_genres_mal($db['user'], sess)
    else
        ret = fetch_genres($db['user'], sess)
    end
    $db['genres'] = ret[:genres]
    $db['seen'] = ret[:seen]
end

if commands[0] == 'list'
    puts $db['genres'].map { |gv| "#{gv[0]} (#{gv[1]}): %.2f ±%.2f" % gv[2..3] } * "\n"
elsif commands[0] == 'recommend'
    season_user = commands[1]
    year = commands[2]

    season = user = nil
    if season_user
        if year
            season = season_user
        else
            user = season_user
        end
    end

    die("Usage: recommend <season> <year>   # recommends anime from that season\n" +
        "       recommend <user>            # recommends anime that user has completed watching\n" +
        "       recommend                   # recommends anime from the highscore list", 0) if options['--help']

    weighted_genres = {}
    $db['genres'].each do |gv|
        prefix = /^[^:]+/.match(gv[0])
        prefix_weight = PREFIX_WEIGHTS[prefix[0]]
        prefix_weight = 1.0 unless prefix_weight
        if prefix == 'Staff'
            prefix = /^[^:]+:[^:]+/.match(gv[0])
            prefix_weight = PREFIX_WEIGHTS[prefix[0]] if PREFIX_WEIGHTS[prefix[0]]
        end

        weighted_sd = gv[3] + 4.0 / gv[1]
        weighted_sd /= prefix_weight
        weighted_genres[gv[0]] = [gv[2], 1.0 / (1.0 + weighted_sd)]
    end

    if user
        list = sess.get("user/#{user}/animelist")['lists']['completed'].map do |a|
            a['anime']
        end
    elsif season && year
        list = sess.get('browse/anime', { year: year, season: season, full_page: true })
    else
        list = sess.get('browse/anime', { sort: 'score-desc', page: 0 }) +
               sess.get('browse/anime', { sort: 'score-desc', page: 1 }) +
               sess.get('browse/anime', { sort: 'score-desc', page: 2 })
    end

    list.uniq!

    if options['new']
        list.reject! { |a| $db['seen'].include?(a['id'].to_i) }
    end

    i = 0
    n = list.length

    list.map! { |a|
        full = sess.get("anime/#{a['id']}/page")

        gm = expanded_genres(full, :extra).map { |g| weighted_genres[g] }.select { |ws| ws }
        if gm.empty?
            calc_score = -Float::INFINITY
            weight = 0.0
            calculation = nil
        else
            weight = gm.map { |ws| ws[1] }.inject(:+)
            calc_score = gm.map { |ws| ws[0] * ws[1] }.inject(:+) / weight
            calculation = expanded_genres(full, :extra).map { |g|
                [g, weighted_genres[g]]
            }.select { |ws| ws[1] }.sort { |ws1, ws2|
                ws2[1][1] <=> ws1[1][1]
            }.map { |ws|
                "#{ws[0]} (%.2f * %.2f)" % [ws[1][0], ws[1][1]]
            } * ', '
        end

        i += 1
        print "#{i}/#{n}\r"
        $stdout.flush

        title = "#{a['title_romaji']}"
        if a['title_romaji'] != a['title_english']
            title += " (#{a['title_english']})"
        end

        { id:           a['id'],
          title:        title,
          avg_score:    a['average_score'],
          eps:          a['total_episodes'],
          calc_score:   calc_score,
          weight:       weight,
          calculation:  calculation }
    }
    puts

    list.sort! { |x, y|
        y[:calc_score] <=> x[:calc_score]
    }

    weight_classes = []
    wc = 0
    until list.empty?
        weight_classes[wc] = list.select { |a| a[:weight] < wc + 1 }
        list -= weight_classes[wc]
        wc += 1
    end

    weight_classes.map.with_index { |wco, i| i }.reverse.each do |wc|
        puts
        puts "=== weight class #{wc}+ ==="
        puts
        puts weight_classes[wc].map { |a|
            "- C %.2f (w %.1f), A %.2f: #{a[:title]} (#{a[:id]}, #{a[:eps]} episodes)\n  #{a[:calculation]}" % [a[:calc_score], a[:weight], a[:avg_score]]
        } * "\n"
    end
elsif commands[0] == 'help'
    puts 'Global options:'
    puts ' --client-id=...'
    puts ' --client-secret=...'
    puts '    Obtain these from http://anilist.co/developer'
    puts
    puts ' --user=...'
    puts '    User to fetch scores from'
    puts
    puts
    puts 'Commands:'
    puts ' help'
    puts '    Does this'
    puts
    puts ' list'
    puts '    Lists the genre votings'
    puts
    puts ' recommend <season> <year>'
    puts '    Recommands anime from the given season and year, based on the genre'
    puts '    votings'
else
    die('Command expected, try "help"')
end

IO.write('anilist.db', JSON.pretty_generate($db))
