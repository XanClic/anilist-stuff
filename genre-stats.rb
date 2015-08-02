#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'net/https'
require 'uri'


$db = nil


def die(msg)
    $stderr.puts(msg)
    IO.write('anilist.db', JSON.pretty_generate($db))
    exit 1
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


def fetch_genres(user, sess)
    completed_list = sess.get("user/#{user}/animelist")['lists']['completed']

    genre_votes = {}

    completed_list.each do |a|
        anime = sess.get("anime/#{a['anime']['id']}")

        anime['genres'].each do |genre|
            genre_votes[genre] = [] unless genre_votes[genre]
            genre_votes[genre] << a['score'].to_f
        end
    end

    genre_votes.map { |g, v|
        [ g, v.length, v.average, v.sd ]
    }.sort { |gv1, gv2|
        gv2[2] <=> gv1[2]
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

if commands[0] != 'help' && (!$db['genres'] || user_changed)
    $db['genres'] = fetch_genres($db['user'], sess)
end

if commands[0] == 'list'
    puts $db['genres'].map { |gv| "#{gv[0]} (#{gv[1]}): %.2f ±%.2f" % gv[2..3] } * "\n"
elsif commands[0] == 'recommend'
    season = commands[1]
    year = commands[2]

    die('Usage: recommend <season> <year>') unless year && season

    weighted_genres = {}
    $db['genres'].each do |gv|
        weighted_sd = gv[3] + 4.0 / gv[1]
        weighted_genres[gv[0]] = [gv[2], 1.0 / (1.0 + weighted_sd)]
    end

    list = sess.get('browse/anime', { year: year, season: season })
    list.map! { |a|
        full = sess.get("anime/#{a['id']}")

        gm = full['genres'].map { |g| weighted_genres[g] }.select { |ws| ws }
        if gm.empty?
            calc_score = -Float::INFINITY
        else
            calc_score = gm.map { |ws| ws[0] * ws[1] }.inject(:+) / gm.map { |ws| ws[1] }.inject(:+)
        end

        { id:           a['id'],
          title:        a['title_english'],
          avg_score:    a['average_score'],
          eps:          a['total_episodes'],
          calc_score:   calc_score }
    }
    list.sort! { |x, y|
        y[:calc_score] <=> x[:calc_score]
    }

    puts list.map { |a|
        "#{a[:title]} (#{a[:id]}, #{a[:eps]} episodes): Avg. score %.2f, calc. score %.2f" % [a[:avg_score], a[:calc_score]]
    } * "\n"
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
